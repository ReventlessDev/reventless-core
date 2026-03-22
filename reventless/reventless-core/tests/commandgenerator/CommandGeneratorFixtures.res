S.enableJson()

// ─────────────────────────────────────────────────────────────
// Aggregate spec for CommandGenerator tests
// ─────────────────────────────────────────────────────────────

module CmdGenAggSpec = {
  module Id = Reventless.Id.StringPure
  let name = "TestCmdGenAgg"

  // Zero-param variant (serializes as plain string)
  // Multi-param variant (serializes as {TAG, name} object)
  @schema
  type command =
    | Create
    | CreateWithName({name: string})
    | Invalid  // used for schema validation tests

  @schema
  type event =
    | Created
    | CreatedWithName({name: string})

  @schema
  type error = | InvalidCommand

  let moduleUrl: string = %raw(`import.meta.url`)
}

// ─────────────────────────────────────────────────────────────
// Behavior
// ─────────────────────────────────────────────────────────────

module CmdGenBehavior = {
  module Spec = CmdGenAggSpec
  type state = unit

  let resolverConfig: Reventless.Behavior.resolverConfig<CmdGenAggSpec.command> = {
    commandSchema: CmdGenAggSpec.commandSchema,
    fields: [],
  }

  let moduleUrl: string = %raw(`import.meta.url`)

  let init = (_event: CmdGenAggSpec.event): state => ()
  let apply = (_state: state, _event: CmdGenAggSpec.event): state => ()

  let create = (command: CmdGenAggSpec.command, _ctx, _errHandler): array<CmdGenAggSpec.event> =>
    switch command {
    | Create => [CmdGenAggSpec.Created]
    | CreateWithName({name}) => [CmdGenAggSpec.CreatedWithName({name: name})]
    | Invalid => []
    }

  let execute = (_state: state, _command: CmdGenAggSpec.command, _ctx, _errHandler): array<
    CmdGenAggSpec.event,
  > => []
}

// ─────────────────────────────────────────────────────────────
// Mock publishJsons — captures published commands
// ─────────────────────────────────────────────────────────────

let capturedCmds: ref<array<Message.commandJson>> = ref([])

module MockPublishSpec: CommandGenerator_Callback.Spec = {
  let publishJsons: CommandGenerator.publishJsons = async cmds => {
    capturedCmds := capturedCmds.contents->Array.concat(cmds)
  }
}

// ─────────────────────────────────────────────────────────────
// CommandGenerator handler under test
// ─────────────────────────────────────────────────────────────

module TestGenerator = CommandGenerator_Callback.Make(MockPublishSpec, CmdGenAggSpec, CmdGenBehavior)

// ─────────────────────────────────────────────────────────────
// Payload builders
// ─────────────────────────────────────────────────────────────

// Build a payload for a zero-param command
let makeZeroParamPayload = (~id, ~command): CommandGenerator.payload =>
  Obj.magic({
    "command": command,
    "arguments": {"id": id},
    "meta": {"ip": ["127.0.0.1"], "user": "test-user", "info": ""},
  })

// Build a payload for a single extra-param command
let makeOneParamPayload = (~id, ~command, ~paramName, ~paramValue): CommandGenerator.payload =>
  Obj.magic({
    "command": command,
    "arguments": Obj.magic(
      Dict.fromArray([
        ("id", JSON.Encode.string(id)),
        (paramName, JSON.Encode.string(paramValue)),
      ]),
    ),
    "meta": {"ip": ["127.0.0.1"], "user": "test-user", "info": ""},
  })

let reset = () => {
  capturedCmds := []
}
