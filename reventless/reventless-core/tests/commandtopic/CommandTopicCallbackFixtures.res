S.enableJson()

// ─────────────────────────────────────────────────────────────
// Command spec for CommandTopic_Callback tests
// ─────────────────────────────────────────────────────────────

// Not annotated with `: Reventless.CommandTopic.T` — keeps Id.t transparent (= string)
// so string literals can be used as IDs and as `reference` field without coercion.
module TestSpec = {
  module Id = Reventless.Id.StringPure
  let name = "TestCommandTopic"

  @schema
  type command =
    | CreateItem({itemId: string})
    | DeleteItem({itemId: string})
}

// ─────────────────────────────────────────────────────────────
// Captures
// ─────────────────────────────────────────────────────────────

type capturedItem = {
  reference: string,
  command: TestSpec.command,
}

let capturedItems: ref<array<capturedItem>> = ref([])
let commandHandlerResults: ref<array<result<string, string>>> = ref([Ok("ref-1")])
let commandHandlerShouldThrow: ref<bool> = ref(false)

// ─────────────────────────────────────────────────────────────
// Ops module
// ─────────────────────────────────────────────────────────────

module TestOps: CommandTopic_Callback.Ops with module Spec = TestSpec = {
  module Spec = TestSpec
  let commandsHandler = async items => {
    if commandHandlerShouldThrow.contents {
      JsError.throwWithMessage("commandsHandler failed")
    }
    capturedItems :=
      capturedItems.contents->Array.concat(
        items->Array.map((item: Reventless.CommandTopic.topicItem<
          Message.command'<TestSpec.Id.t, TestSpec.command>,
        >) => {
          reference: item.reference,
          command: item.command.command,
        }),
      )
    commandHandlerResults.contents
  }
}

module TestHandler = CommandTopic_Callback.Make(TestSpec, TestOps)

// ─────────────────────────────────────────────────────────────
// Test helpers
// ─────────────────────────────────────────────────────────────

let testMeta: Message.meta = {
  service: "TestService",
  time: "2024-01-01T00:00:00Z",
  ip: "127.0.0.1",
  user: "test-user",
  msgId: "cmd-msg-1",
  correlationId: "cmd-corr-1",
}

let makeCommandJson = (id, command): JSON.t => {
  let cmd': Message.command'<TestSpec.Id.t, TestSpec.command> = {id, meta: testMeta, command}
  cmd'->Message.encodeCommand'(TestSpec.Id.schema, TestSpec.commandSchema)
}

let makeTopicItem = (id, command): ReventlessCore.CommandTopic.topicItem<JSON.t> => {
  reference: id,
  command: makeCommandJson(id, command),
}

let reset = () => {
  capturedItems := []
  commandHandlerResults := [Ok("ref-1")]
  commandHandlerShouldThrow := false
}
