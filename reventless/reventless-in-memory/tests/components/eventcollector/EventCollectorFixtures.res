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
let topicResource: ReventlessInfra.Adapter.resource = ReventlessInfra.Adapter.make(
  ~name=topicName->Pulumi.Output.make,
  ~id=topicName->Pulumi.Output.make,
  ~urn=topicName->Pulumi.Output.make,
  ~service="memory:InMemory"->Pulumi.Output.make,
)
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

