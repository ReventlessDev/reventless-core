// Fixtures for SideEffectHandler integration tests.
// Publishes an event to the bus and verifies the side effect execute function is called.

open TestFixtures

S.enableJson()

// ─────────────────────────────────────────────────────────────
// Isolated bus + Pulumi mock mode
// ─────────────────────────────────────────────────────────────

module Bus = InMemory_Bus.Make()
let _ = TestRunner.setup()

// ─────────────────────────────────────────────────────────────
// Source event spec
// ─────────────────────────────────────────────────────────────

module TestSEHSource = {
  module Id = Reventless.Id.StringPure
  let name = "TestSEHSource"

  @schema
  type event = | OrderPlaced({orderId: string})
}

// ─────────────────────────────────────────────────────────────
// Captured state
// ─────────────────────────────────────────────────────────────

// Each entry: (aggregateId, orderId)
let capturedOrders: ref<array<(string, string)>> = ref([])

// ─────────────────────────────────────────────────────────────
// Side effect implementation
// ─────────────────────────────────────────────────────────────

module TestSideEffect = {
  module Source = TestSEHSource

  let execute = async (
    id: TestSEHSource.Id.t,
    _meta: Reventless.Message.meta,
    event: TestSEHSource.event,
    _queryEngine: Reventless.QueryEngine.operations,
  ) => {
    switch event {
    | OrderPlaced({orderId}) =>
      capturedOrders := capturedOrders.contents->Array.concat([(id, orderId)])
    }
  }
}

// ─────────────────────────────────────────────────────────────
// EventCollector wiring (core EventCollector_Builder + in-memory adapters)
// ─────────────────────────────────────────────────────────────

module EventCollectorCh = EventCollectorChannel_InMemory.Make(Bus)
module SpecificEventCollector = ReventlessCore.EventCollector_Builder.Make(
  RuntimeEnvironment_InMemory,
  EventCollectorCh,
)
module ECRTBuilder = EventCollectorRuntime_Builder_InMemory.Make(Bus, EventCollectorCh)

module SEHBuilder = ReventlessCore.SideEffectHandler_Builder.Make(
  RuntimeEnvironment_InMemory,
  EventCollectorCh,
  SpecificEventCollector,
  ECRTBuilder,
)

// ─────────────────────────────────────────────────────────────
// allEventTopics — keyed by Source.name, resource.name = bus topic key
// ─────────────────────────────────────────────────────────────

let topicName = "TestSEHSource"
let topicResource: ReventlessInfra.Adapter.resource = {
  name: topicName->Pulumi.Output.make,
  id: topicName->Pulumi.Output.make,
  urn: topicName->Pulumi.Output.make,
  info: ""->Pulumi.Output.make,
  service: "InMemory"->Pulumi.Output.make,
}

let allEventTopics: ReventlessInfra.EventTopic.allOutputs = Dict.fromArray([
  ("TestSEHSource", {ReventlessInfra.EventTopic.resources: [topicResource]}),
])

// ─────────────────────────────────────────────────────────────
// Build SideEffectHandler component
// ─────────────────────────────────────────────────────────────

let sideEffects: array<module(Reventless.SideEffect.T)> = [module(TestSideEffect)]

let seh = SEHBuilder.make(
  ~name="TestSEH",
  ~sideEffects,
  ~allEventTopics,
  ~allCommandTopics=Pulumi.Output.make(Dict.make()),
  ~queryEngine=mockQueryEngine,
  ~scheduler=mockScheduler,
  ~resourceNaming=mockResourceNaming,
)

// ─────────────────────────────────────────────────────────────
// Test meta
// ─────────────────────────────────────────────────────────────

let testMeta = makeTestMeta(~service="TestSEHSource")

// ─────────────────────────────────────────────────────────────
// Publish helper — emits {id, meta, event} to the bus topic
// meta.service must match TestSEHSource.name for the callback to route correctly
// ─────────────────────────────────────────────────────────────

let publishOrderPlaced = async (id, orderId) => {
  let eventJson = JSON.Encode.object(
    Dict.fromArray([
      ("id", id->JSON.Encode.string),
      ("meta", testMeta->S.reverseConvertToJsonOrThrow(Reventless.Message.metaSchema)),
      (
        "event",
        TestSEHSource.OrderPlaced({orderId: orderId})
        ->S.reverseConvertToJsonOrThrow(TestSEHSource.eventSchema),
      ),
    ]),
  )
  await Bus.publishEvent(topicName, "TestSEHSource", testMeta, eventJson)
}

let resetMocks = () => {
  capturedOrders := []
}
