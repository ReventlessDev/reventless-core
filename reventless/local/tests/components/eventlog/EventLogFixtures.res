// Integration test fixtures for EventLog builder (in-memory).

open TestFixtures

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

module Bus = LocalBus.Make()

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
  LocalEventTopicPublisher.Make(Bus),
)

let eventLog = EventLogMaker.make(~name="TestItemEventLog")

let makeEvent' = (id, event) => ({
  Reventless.Message.id,
  meta: testMeta,
  event,
}: Reventless.Message.event'<string, ItemEventLogSpec.event>)

let reset = () => {
  capturedTopicEventCount := 0
}
