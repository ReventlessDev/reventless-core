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
// Behavior
// ─────────────────────────────────────────────────────────────

module CGBehavior = {
  module Spec = CGSpec
  type state = {name: string}

  let moduleUrl: string = %raw(`import.meta.url`)

  let initialState = {name: ""}

  let evolve = (_state: state, event: CGSpec.event): state =>
    switch event {
    | CGItemCreated({name}) => {name: name}
    }

  let decide = (_state: state, command: CGSpec.command): result<array<CGSpec.event>, CGSpec.error> =>
    switch command {
    | CreateCGItem({name}) => Ok([CGSpec.CGItemCreated({name: name})])
    }
}

// ─────────────────────────────────────────────────────────────
// CommandGenerator builder (in-memory resolvers = no AppSync)
// ─────────────────────────────────────────────────────────────

module CGMaker = ReventlessCore.CommandGenerator_Builder.Make(
  CGSpec,
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
