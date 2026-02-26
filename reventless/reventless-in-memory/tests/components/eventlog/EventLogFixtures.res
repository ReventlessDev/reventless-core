// Integration test fixtures for EventLog builder (in-memory).

// ─────────────────────────────────────────────────────────────
// Test event spec
// ─────────────────────────────────────────────────────────────

module ItemEventLogSpec = {
  module Id = Reventless.Id.StringPure
  let name = "TestItemEventLog"

  @schema
  type event = | ItemCreated({name: string}) | ItemDeleted({id: string})
}

// ─────────────────────────────────────────────────────────────
// Bus and Pulumi setup
// ─────────────────────────────────────────────────────────────

module Bus = InMemory_Bus.Make()

// Capture events published to the event topic.
// Topic name = Spec.name ++ "EventTopic" = "TestItemEventLogEventTopic"
let capturedTopicEventCount: ref<int> = ref(0)
let _ = Bus.subscribeToEvents("TestItemEventLogEventTopic", async (_, _, _) => {
  capturedTopicEventCount := capturedTopicEventCount.contents + 1
})

let _ = TestRunner.setup()

// ─────────────────────────────────────────────────────────────
// Build EventLog using in-memory adapters directly
// ─────────────────────────────────────────────────────────────

module EventLogMaker = ReventlessCore.EventLog_Builder.Make(
  ItemEventLogSpec,
  EventLogStorage_InMemory,
  EventTopicPublisher_InMemory.Make(Bus),
)

let eventLog = EventLogMaker.make(~name="TestItemEventLog")

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

let makeEvent' = (id, event) => ({
  Reventless.Message.id,
  meta: testMeta,
  event,
}: Reventless.Message.event'<string, ItemEventLogSpec.event>)

let reset = () => {
  capturedTopicEventCount := 0
}
