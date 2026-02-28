// Tests for EventTopic.publishJsonStream (Phase I of effect-stream-integration plan).
// Verifies that a Stream<publishJsonStreamItem> drives publishing without collecting into an array.

open AsyncTest
open AsyncTest.Expect

// ─────────────────────────────────────────────────────────────
// Spec, Bus, and Component (module-level, one Pulumi setup)
// ─────────────────────────────────────────────────────────────

module ItemStreamSpec = {
  module Id = Reventless.Id.StringPure
  let name = "StreamEvtItem"

  @schema
  type event = | ItemPublished({name: string}) | ItemRemoved({id: string})
}

module StreamEvtBus = InMemory_Bus.Make()

let _ = TestRunner.setup()

// Topic name = make name ++ "EventTopic" = "StreamEvtTopic" ++ "EventTopic"
let received: ref<int> = ref(0)
let _ = StreamEvtBus.subscribeToEvents("StreamEvtTopicEventTopic", async (_, _, _) => {
  received := received.contents + 1
})

module StreamEvtTopicMaker = ReventlessCore.EventTopic_Builder.Make(
  ItemStreamSpec,
  EventTopicPublisher_InMemory.Make(StreamEvtBus),
)

let evtTopic = StreamEvtTopicMaker.make(~name="StreamEvtTopic", ~storageResources=[])

let testMeta: Reventless.Message.meta = {
  service: "test",
  time: "2024-01-01T00:00:00.000Z",
  ip: "127.0.0.1",
  user: "testuser",
  msgId: "msg-002",
  correlationId: "corr-002",
}

// ─────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────

describe("EventTopic.publishJsonStream", () => {
  let _ = beforeAllAsync(async () => {
    let _ = await evtTopic->ReventlessCore.Component.operations->TestRunner.resolve
  })

  let _ = beforeEach(() => {
    received := 0
  })

  testPromise("streams 2 events to all subscribers", async () => {
    let ops = await evtTopic->ReventlessCore.Component.operations->TestRunner.resolve
    let stream = [
      ({service: "svc", meta: testMeta, json: JSON.parseOrThrow("{\"ev\":1}")}: Reventless.EventTopic.publishJsonStreamItem),
      {service: "svc", meta: testMeta, json: JSON.parseOrThrow("{\"ev\":2}")},
    ]->Stream.fromIterable
    let _ = await ops.publishJsonStream(stream)->Effect.runPromise
    let _ = await Promise.resolve()
    let _ = await Promise.resolve()
    expect(received.contents)->toBe(2)
  })

  testPromise("empty stream publishes nothing to subscribers", async () => {
    let ops = await evtTopic->ReventlessCore.Component.operations->TestRunner.resolve
    let _ = await ops.publishJsonStream(Stream.empty)->Effect.runPromise
    let _ = await Promise.resolve()
    expect(received.contents)->toBe(0)
  })
})
