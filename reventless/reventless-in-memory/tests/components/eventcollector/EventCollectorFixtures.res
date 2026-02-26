// Integration test fixtures for EventCollector builder (in-memory).

// ─────────────────────────────────────────────────────────────
// Bus and Pulumi setup
// ─────────────────────────────────────────────────────────────

module Bus = InMemory_Bus.Make()

let _ = TestRunner.setup()

// ─────────────────────────────────────────────────────────────
// Build a minimal EventTopic resource for the EventCollector to subscribe to
// ─────────────────────────────────────────────────────────────

let topicName = "TestECEventTopic"
let topicResource: Reventless.Adapter.resource = {
  name: topicName->Pulumi.Output.make,
  id: topicName->Pulumi.Output.make,
  urn: topicName->Pulumi.Output.make,
  info: ""->Pulumi.Output.make,
  service: "InMemory"->Pulumi.Output.make,
}
let allEventTopics: ReventlessCore.EventTopic.allOutputs = Dict.fromArray([
  (topicName, ({resources: [topicResource]}: ReventlessCore.EventTopic.outputs)),
])

// ─────────────────────────────────────────────────────────────
// Captured events
// ─────────────────────────────────────────────────────────────

let capturedEvents: ref<array<JSON.t>> = ref([])

// ─────────────────────────────────────────────────────────────
// Build EventCollector
// ─────────────────────────────────────────────────────────────

module EventCollectorMaker = ReventlessCore.EventCollector_Builder.Make(
  RuntimeEnvironment_InMemory,
  EventCollectorChannel_InMemory.Make(Bus),
)

let eventCollector = EventCollectorMaker.make(~name="TestEC", ~eventTopics=allEventTopics, ~opts={})

// ─────────────────────────────────────────────────────────────
// Test metadata
// ─────────────────────────────────────────────────────────────

let testMeta: Reventless.Message.meta = {
  service: "test",
  time: "2024-01-01T00:00:00.000Z",
  ip: "127.0.0.1",
  user: "testuser",
  msgId: "msg-001",
  correlationId: "corr-001",
}
