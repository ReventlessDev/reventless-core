// Fixtures for testing a ReadModel that subscribes to two independent event sources.
// Verifies the mixed-source capability where Plugin_Builder merges both aggregate
// and DCB EventTopics into allEventTopics (Step 1.1 of hybrid improvements).

open TestFixtures
open Reventless
open Reventless.Projection

// ─────────────────────────────────────────────────────────────
// ReadModel spec — unified view combining events from two sources
// ─────────────────────────────────────────────────────────────

module MixedReadModelSpec = {
  module Id = Reventless.Id.String
  let name = "TestMixedReadModel"
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type state = {
    name: string,
    source: string,
  }

  let config = ReadModel.config()
  let subIdConfig = None
}

// ─────────────────────────────────────────────────────────────
// Source 1: simulates an aggregate EventTopic
// ─────────────────────────────────────────────────────────────

module AggregateSource = {
  module Id = Reventless.Id.String
  let name = "TestAggregateEventTopic"

  @schema
  type event =
    | AggregateItemCreated({name: string})
    | AggregateItemRenamed({name: string})
}

// ─────────────────────────────────────────────────────────────
// Source 2: simulates a DCB EventTopic
// ─────────────────────────────────────────────────────────────

module DcbSource = {
  module Id = Reventless.Id.String
  let name = "TestDcbEventTopic"

  @schema
  type event =
    | DcbItemAdded({name: string})
    | DcbItemNameChanged({name: string})
}

// ─────────────────────────────────────────────────────────────
// Mapping 1: Aggregate events → ReadModel state
// ─────────────────────────────────────────────────────────────

module AggregateMapping = Mapping.Make(
  AggregateSource,
  MixedReadModelSpec,
  {
    let project = (msg: Message.event'<string, AggregateSource.event>) =>
      switch msg.event {
      | AggregateItemCreated({name}) =>
        Create(msg.id, ({name, source: "aggregate"}: MixedReadModelSpec.state))
      | AggregateItemRenamed({name}) => Update(msg.id, state => {...state, name})
      }
  },
)

// ─────────────────────────────────────────────────────────────
// Mapping 2: DCB events → ReadModel state
// ─────────────────────────────────────────────────────────────

module DcbMapping = Mapping.Make(
  DcbSource,
  MixedReadModelSpec,
  {
    let project = (msg: Message.event'<string, DcbSource.event>) =>
      switch msg.event {
      | DcbItemAdded({name}) =>
        Create(msg.id, ({name, source: "dcb"}: MixedReadModelSpec.state))
      | DcbItemNameChanged({name}) => Update(msg.id, state => {...state, name})
      }
  },
)

// ─────────────────────────────────────────────────────────────
// Mappings module with both sources
// ─────────────────────────────────────────────────────────────

module MixedMappings: Mappings with module Target := MixedReadModelSpec = {
  module Mappings = Mappings.Make(MixedReadModelSpec)
  module type Mapping = Mappings.Mapping
  let moduleUrl: string = %raw(`import.meta.url`)
  let mappings: array<module(Mapping)> = [module(AggregateMapping), module(DcbMapping)]
}

// ─────────────────────────────────────────────────────────────
// allEventTopics — two entries, one per source
// ─────────────────────────────────────────────────────────────

let aggregateTopicName = "TestAggregateEventTopic"
let dcbTopicName = "TestDcbEventTopic"

let aggregateResource: ReventlessInfra.Adapter.resource = ReventlessInfra.Adapter.make(
  ~name=aggregateTopicName->Pulumi.Output.make,
  ~id=aggregateTopicName->Pulumi.Output.make,
  ~urn=aggregateTopicName->Pulumi.Output.make,
  ~service="memory:InMemory"->Pulumi.Output.make,
)

let dcbResource: ReventlessInfra.Adapter.resource = ReventlessInfra.Adapter.make(
  ~name=dcbTopicName->Pulumi.Output.make,
  ~id=dcbTopicName->Pulumi.Output.make,
  ~urn=dcbTopicName->Pulumi.Output.make,
  ~service="memory:InMemory"->Pulumi.Output.make,
)

let allEventTopics: ReventlessCore.EventTopic.allOutputs = Dict.fromArray([
  (aggregateTopicName, {ReventlessInfra.EventTopic.resources: [aggregateResource]}),
  (dcbTopicName, {ReventlessInfra.EventTopic.resources: [dcbResource]}),
])

// ─────────────────────────────────────────────────────────────
// Isolated bus + Pulumi mock mode
// ─────────────────────────────────────────────────────────────

module Bus = InMemory_Bus.Make()
let _ = TestRunner.setup()

// ─────────────────────────────────────────────────────────────
// Build ReadModel
// ─────────────────────────────────────────────────────────────

module ReadModelMaker = ReadModel_Builder.Make(Bus)
module MixedRM = ReadModelMaker.Make(MixedReadModelSpec, MixedMappings)
let rm = MixedRM.make(~api=(), ~apiRole=(), ~allEventTopics)

// ─────────────────────────────────────────────────────────────
// Test helpers
// ─────────────────────────────────────────────────────────────

let publishAggregateEvent = async (id, event: AggregateSource.event) => {
  let meta = makeTestMeta(~service="TestAggregateEventTopic")
  let eventJson = JSON.Encode.object(
    Dict.fromArray([
      ("id", id->JSON.Encode.string),
      ("meta", meta->S.reverseConvertToJsonOrThrow(Message.metaSchema)),
      ("event", event->S.reverseConvertToJsonOrThrow(AggregateSource.eventSchema)),
    ]),
  )
  await Bus.publishEvent(aggregateTopicName, "test", meta, eventJson)
}

let publishDcbEvent = async (id, event: DcbSource.event) => {
  let meta = makeTestMeta(~service="TestDcbEventTopic")
  let eventJson = JSON.Encode.object(
    Dict.fromArray([
      ("id", id->JSON.Encode.string),
      ("meta", meta->S.reverseConvertToJsonOrThrow(Message.metaSchema)),
      ("event", event->S.reverseConvertToJsonOrThrow(DcbSource.eventSchema)),
    ]),
  )
  await Bus.publishEvent(dcbTopicName, "test", meta, eventJson)
}

let loadState = async id => {
  switch Bus.getQueryDb("TestMixedReadModel") {
  | None => []
  | Some(ops) =>
    let states =
      await ops.loadStream(id)
      ->Stream.runCollect
      ->Effect.catchAll(_ => Effect.succeed([]))
      ->Effect.runPromise
    states->Array.map(json => json->S.parseJsonOrThrow(MixedReadModelSpec.stateSchema))
  }
}
