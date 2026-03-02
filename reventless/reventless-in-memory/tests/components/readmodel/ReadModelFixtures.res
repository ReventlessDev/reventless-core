// E2E test fixtures for ReadModel builder.
// Builds a ReadModel from a manually constructed allEventTopics and publishes
// events directly via the bus to verify projection into the QueryDb.

open TestFixtures
open Reventless
open Reventless.Projection

// ─────────────────────────────────────────────────────────────
// Minimal ReadModel spec
// ─────────────────────────────────────────────────────────────

module ItemReadModelSpec = {
  module Id = Reventless.Id.String
  let name = "TestItemReadModel"

  @schema
  type state = {name: string}

  let config = ReadModel.config()
  let subIdConfig = None
}

// ─────────────────────────────────────────────────────────────
// Minimal source event
// Used as the projection source — topic name doubles as mapping.sourceName
// ─────────────────────────────────────────────────────────────

module ItemEventSource = {
  module Id = Reventless.Id.String
  let name = "TestItemEventTopic" // must match allEventTopics key AND meta.service in published events

  @schema
  type event = | ItemCreated({name: string})
}

// ─────────────────────────────────────────────────────────────
// Mapping: ItemCreated → Create ReadModel state
// ─────────────────────────────────────────────────────────────

module ItemMapping = Mapping.Make(
  ItemEventSource,
  ItemReadModelSpec,
  {
    let map = (msg: Message.event'<string, ItemEventSource.event>) =>
      switch msg.event {
      | ItemCreated({name}) => Create(msg.id, ({name: name}: ItemReadModelSpec.state))
      }
  },
)

// ─────────────────────────────────────────────────────────────
// Mappings module required by ReadModel_Builder.Make
// ─────────────────────────────────────────────────────────────

module ItemMappings: Mappings with module Target := ItemReadModelSpec = {
  module Mappings = Mappings.Make(ItemReadModelSpec)
  module type Mapping = Mappings.Mapping
  let mappings: array<module(Mapping)> = [module(ItemMapping)]
}

// ─────────────────────────────────────────────────────────────
// allEventTopics — constructed manually (no aggregate needed)
// resource.name is the bus topic key that EventCollectorChannel subscribes to.
// ─────────────────────────────────────────────────────────────

let topicName = "TestItemEventTopic"
let topicResource: ReventlessInfra.Adapter.resource = {
  name: topicName->Pulumi.Output.make,
  id: topicName->Pulumi.Output.make,
  urn: topicName->Pulumi.Output.make,
  info: ""->Pulumi.Output.make,
  service: "InMemory"->Pulumi.Output.make,
}
let allEventTopics: ReventlessInfra.EventTopic.allOutputs = Dict.fromArray([
  (topicName, {ReventlessInfra.EventTopic.resources: [topicResource]}),
])

// ─────────────────────────────────────────────────────────────
// Isolated bus for this test suite
// ─────────────────────────────────────────────────────────────

module Bus = InMemory_Bus.Make()

// ─────────────────────────────────────────────────────────────
// Activate Pulumi mock mode (must be before any Component.make)
// ─────────────────────────────────────────────────────────────

let _ = TestRunner.setup()

// ─────────────────────────────────────────────────────────────
// Build ReadModel
// ─────────────────────────────────────────────────────────────

module ReadModelMaker = ReadModel_Builder.Make(Bus)
module ItemReadModel = ReadModelMaker.Make(ItemReadModelSpec, ItemMappings)
let rm = ItemReadModel.make(~api=(), ~apiRole=(), ~allEventTopics)

// ─────────────────────────────────────────────────────────────
// Test helpers
// ─────────────────────────────────────────────────────────────

// meta.service MUST match Mapping.sourceName ("TestItemEventTopic") for
// ReadModel_Callback to route the event to the correct mapping.
let testMeta = makeTestMeta(~service="TestItemEventTopic")

// Publish a typed event to the bus topic.
// The event JSON must be {id, meta, event} format for Message.decodeEvent' to parse.
let publishItemCreated = async (id, name) => {
  let eventJson = JSON.Encode.object(
    Dict.fromArray([
      ("id", id->JSON.Encode.string),
      ("meta", testMeta->S.reverseConvertToJsonOrThrow(Message.metaSchema)),
      (
        "event",
        ItemEventSource.ItemCreated({name: name})
        ->S.reverseConvertToJsonOrThrow(ItemEventSource.eventSchema),
      ),
    ]),
  )
  await Bus.publishEvent(topicName, "test", testMeta, eventJson)
}

// Query projected state from the in-memory QueryDb.
// QueryDb is registered as "TestItemReadModelQueryDB"
// (= ReadModel Spec.name ++ ComponentType.toName(QueryDb) = "TestItemReadModel" ++ "QueryDB").
let loadState = async id => {
  switch Bus.getQueryDb("TestItemReadModelQueryDB") {
  | None => []
  | Some(ops) =>
    let states =
      await ops.loadStream(id)
      ->Stream.runCollect
      ->Effect.catchAll(_ => Effect.succeed([]))
      ->Effect.runPromise
    states->Array.map(json => json->S.parseJsonOrThrow(ItemReadModelSpec.stateSchema))
  }
}
