// Tests for CommandTopic.publishJsonsStream (Phase I of effect-stream-integration plan).
// Verifies that a Stream<commandJson> drives publishing without collecting into an array.

open AsyncTest
open AsyncTest.Expect

// ─────────────────────────────────────────────────────────────
// Spec, Bus, and Component (module-level, one Pulumi setup)
// ─────────────────────────────────────────────────────────────

module ItemSpec = {
  module Id = Reventless.Id.String
  let name = "StreamCmdItem"

  @schema
  type command = | CreateItem({name: string}) | DeleteItem({id: string})

  @schema
  type event = | ItemCreated({name: string})

  @schema
  type error = | AlreadyExists
}

module StreamBus = InMemory_Bus.Make()

let _ = TestRunner.setup()

module StreamCmdTopicMaker = ReventlessCore.CommandTopic_Builder.Make(
  ItemSpec,
  CommandTopicChannel_InMemory.Make(StreamBus),
)

let cmdTopic = StreamCmdTopicMaker.make(~name="StreamCmdTopic")

// Track dispatched commands per test — reset in beforeEach
let captured: ref<array<JSON.t>> = ref([])

let _ = StreamBus.registerCommandHandler("StreamCmdTopicCmdTopic", async (body, _ctx) => {
  captured := captured.contents->Array.concat([body])
})

let testMeta: Reventless.Message.meta = {
  service: "test",
  time: "2024-01-01T00:00:00.000Z",
  ip: "127.0.0.1",
  user: "testuser",
  msgId: "msg-001",
  correlationId: "corr-001",
}

let makeJson = (id): Reventless.Message.commandJson => {
  Reventless.Message.id: id,
  meta: testMeta,
  commandJson: ItemSpec.CreateItem({name: id})->ReventlessCore.Message.encode(ItemSpec.commandSchema),
}

// ─────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────

describe("CommandTopic.publishJsonsStream", () => {
  let _ = beforeAllAsync(async () => {
    let _ = await cmdTopic->ReventlessCore.Component.operations->TestRunner.resolve
  })

  let _ = beforeEach(() => {
    captured := []
  })

  testPromise("streams 3 commands to the bus in order", async () => {
    let ops = await cmdTopic->ReventlessCore.Component.operations->TestRunner.resolve
    let stream = [makeJson("cmd-1"), makeJson("cmd-2"), makeJson("cmd-3")]->Stream.fromIterable
    let _ = await ops.publishJsonsStream(stream)->Effect.runPromise
    let _ = await Promise.resolve()
    expect(captured.contents->Array.length)->toBe(3)
  })

  testPromise("empty stream dispatches nothing", async () => {
    let ops = await cmdTopic->ReventlessCore.Component.operations->TestRunner.resolve
    let _ = await ops.publishJsonsStream(Stream.empty)->Effect.runPromise
    let _ = await Promise.resolve()
    expect(captured.contents->Array.length)->toBe(0)
  })
})
