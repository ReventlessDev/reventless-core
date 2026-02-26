// Integration test fixtures for EventTopic builder (in-memory).

module ItemEventTopicSpec = {
  module Id = Reventless.Id.StringPure
  let name = "TestItemEventTopic"

  @schema
  type event = | ItemPublished({name: string}) | ItemRemoved({id: string})
}

// ─────────────────────────────────────────────────────────────
// Bus and Pulumi setup
// ─────────────────────────────────────────────────────────────

module Bus = InMemory_Bus.Make()

// Subscribe before building to capture published events
let capturedEventCount: ref<int> = ref(0)
// Topic name in bus = make name ++ ComponentType.toName(EventTopic) = "TestItemEventTopic" ++ "EventTopic"
let _ = Bus.subscribeToEvents("TestItemEventTopicEventTopic", async (_, _, _) => {
  capturedEventCount := capturedEventCount.contents + 1
})

let _ = TestRunner.setup()

// ─────────────────────────────────────────────────────────────
// Build EventTopic using in-memory publisher
// ─────────────────────────────────────────────────────────────

module EventTopicMaker = ReventlessCore.EventTopic_Builder.Make(
  ItemEventTopicSpec,
  EventTopicPublisher_InMemory.Make(Bus),
)

let eventTopic = EventTopicMaker.make(~name="TestItemEventTopic", ~storageResources=[])

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
}: Reventless.Message.event'<string, ItemEventTopicSpec.event>)

let reset = () => {
  capturedEventCount := 0
}
