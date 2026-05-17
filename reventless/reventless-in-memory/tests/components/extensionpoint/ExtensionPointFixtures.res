// Fixtures for ExtensionPoint integration tests.
// Verifies that dispatching a command to the EP channel calls publishToAggregates.

open TestFixtures


// ─────────────────────────────────────────────────────────────
// Isolated bus + Pulumi mock mode
// ─────────────────────────────────────────────────────────────

module Bus = InMemory_Bus.Make()
let _ = TestRunner.setup()

// ─────────────────────────────────────────────────────────────
// ExtensionPoint spec
// EP CommandTopic channel = Spec.name ++ "ExtPoint" ++ "CmdTopic" = "TestEPExtPointCmdTopic"
// ─────────────────────────────────────────────────────────────

module TestEPSpec = {
  let name = "TestEP"

  @schema
  type command = | Forward({targetId: string})

  @schema
  type event = | TEPNoEvent // unused — mapOutgoingEvent = None

  @schema
  type directive = | TEPNoDirective // unused — mapIncomingCommand only uses PublishCommand

  let moduleUrl: string = %raw(`import.meta.url`)
}

// ─────────────────────────────────────────────────────────────
// Target aggregate spec (receives forwarded commands)
// ─────────────────────────────────────────────────────────────

module DelegateAggSpec = {
  module Id = Reventless.Id.StringPure
  let name = "TargetAgg"

  @schema
  type command = | Execute({targetId: string})

  @schema
  type event = | Executed({targetId: string}) // unused but required by Aggregate.Spec

  @schema
  type error = | TEAggNoError // unused but required by Aggregate.Spec

  let moduleUrl: string = %raw(`import.meta.url`)
}

// ─────────────────────────────────────────────────────────────
// Mapping: Forward → Execute
// ─────────────────────────────────────────────────────────────

module ForwardMapping = {
  module ExtensionPoint = TestEPSpec
  module Delegate = DelegateAggSpec

  let mapIncomingCommand = (
    _id: string,
    cmd: TestEPSpec.command,
    _meta: Reventless.Message.meta,
  ): array<ReventlessInfra.ExtensionPointMapping.commandAction<DelegateAggSpec.command, TestEPSpec.directive>> =>
    switch cmd {
    | Forward({targetId}) =>
      let execCmd = DelegateAggSpec.Execute({targetId: targetId})
      [ReventlessInfra.ExtensionPointMapping.PublishCommand(targetId, execCmd)]
    }

  let mapOutgoingEvent: option<
    ReventlessInfra.ExtensionPointMapping.mapOutgoingEvent<
      DelegateAggSpec.event,
      TestEPSpec.event,
      TestEPSpec.directive,
    >,
  > = None
}

// ─────────────────────────────────────────────────────────────
// Pre-compiled mapping (Spec + Impl → T)
// ─────────────────────────────────────────────────────────────

module TestEPMapping1 = ReventlessInfra.ExtensionPointMapping.Make(ForwardMapping)

// ─────────────────────────────────────────────────────────────
// Mappings collection satisfying ExtensionPoint.Mappings
// ─────────────────────────────────────────────────────────────

module TestEPMappings = {
  module Spec = TestEPSpec
  module type Mapping = ReventlessInfra.ExtensionPointMapping.T with module ExtensionPoint := TestEPSpec
  let name = "TestEPMappings"
  let moduleUrl: string = %raw(`import.meta.url`)
  let mappings: array<module(Mapping)> = [module(TestEPMapping1)]
}

// ─────────────────────────────────────────────────────────────
// In-memory ExtensionPoint builder
// ─────────────────────────────────────────────────────────────

module EPBuilderWithBus = ExtensionPoint_Builder.Make(Bus)
module TestEP = EPBuilderWithBus.Make(TestEPSpec, TestEPMappings)

// ─────────────────────────────────────────────────────────────
// Captured state
// ─────────────────────────────────────────────────────────────

let capturedCmds: ref<array<Reventless.Message.commandJson>> = ref([])

// ─────────────────────────────────────────────────────────────
// Mock infrastructure
// ─────────────────────────────────────────────────────────────

let mockPublishFn: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
  capturedCmds := capturedCmds.contents->Array.concat(cmds)
}

// ─────────────────────────────────────────────────────────────
// Build ExtensionPoint component
// ─────────────────────────────────────────────────────────────

let ep = TestEP.make(
  ~aggregateResources=Dict.fromArray([("TargetAgg", [])]),
  ~publishToAggregates=Dict.fromArray([("TargetAgg", mockPublishFn)]),
  ~scheduler=mockScheduler,
  ~queryEngine=mockQueryEngine,
  ~resourceNaming=mockResourceNaming,
  ~opts=None,
)

// ─────────────────────────────────────────────────────────────
// Test meta + helpers
// ─────────────────────────────────────────────────────────────

let testMeta = makeTestMeta(~service="TestEP")

let resetMocks = () => {
  capturedCmds := []
}
