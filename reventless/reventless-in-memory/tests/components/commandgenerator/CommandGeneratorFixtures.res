// Fixtures for CommandGenerator integration tests.
// Verifies that makeHandler builds a resolver that publishes the correct commandJson.

S.enableJson()

// Activate Pulumi mock mode (must be called before any Component.make)
let _ = TestRunner.setup()

// ─────────────────────────────────────────────────────────────
// Aggregate spec (matches the Behavior used in CommandGenerator_Builder.Make)
// ─────────────────────────────────────────────────────────────

module CGSpec = {
  module Id = Reventless.Id.StringPure
  let name = "TestCGAggregate"

  @schema
  type command = | CreateCGItem({name: string})

  @schema
  type event = | CGItemCreated({name: string})

  @schema
  type error = | CGAlreadyExists

  let moduleUrl: string = %raw(`import.meta.url`)
}

// ─────────────────────────────────────────────────────────────
// Behavior (provides resolverConfig used by CommandGenerator_Callback)
// ─────────────────────────────────────────────────────────────

module CGBehavior = {
  module Spec = CGSpec
  type state = {name: string}

  let resolverConfig: Reventless.Behavior.resolverConfig<CGSpec.command> = {
    commandSchema: CGSpec.commandSchema,
    fields: ["name"],
  }

  let moduleUrl: string = %raw(`import.meta.url`)

  let init = (event: CGSpec.event): state =>
    switch event {
    | CGItemCreated({name}) => {name: name}
    }

  let apply = (_state: state, event: CGSpec.event): state =>
    switch event {
    | CGItemCreated({name}) => {name: name}
    }

  let create = (command: CGSpec.command, _ctx, _errHandler): array<CGSpec.event> =>
    switch command {
    | CreateCGItem({name}) => [CGSpec.CGItemCreated({name: name})]
    }

  let execute = (_state: state, _command: CGSpec.command, _ctx, _errHandler): array<
    CGSpec.event,
  > => []
}

// ─────────────────────────────────────────────────────────────
// CommandGenerator builder (in-memory resolvers = no AppSync)
// ─────────────────────────────────────────────────────────────

module CGMaker = ReventlessCore.CommandGenerator_Builder.Make(
  CGSpec,
  CGBehavior,
  CommandGeneratorResolvers_InMemory,
)

// ─────────────────────────────────────────────────────────────
// Captured commands
// ─────────────────────────────────────────────────────────────

let capturedCmds: ref<array<Reventless.Message.commandJson>> = ref([])

let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
  capturedCmds := capturedCmds.contents->Array.concat(cmds)
}

let resetMocks = () => {
  capturedCmds := []
}
