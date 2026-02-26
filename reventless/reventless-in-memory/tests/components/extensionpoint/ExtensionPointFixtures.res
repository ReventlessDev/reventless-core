// Fixtures for ExtensionPoint integration tests.
// Verifies that dispatching a command to the EP channel calls publishToAggregates.

S.enableJson()

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
}

// ─────────────────────────────────────────────────────────────
// Target aggregate spec (receives forwarded commands)
// ─────────────────────────────────────────────────────────────

module TargetAggSpec = {
  module Id = Reventless.Id.StringPure
  let name = "TargetAgg"

  @schema
  type command = | Execute({targetId: string})

  @schema
  type event = | Executed({targetId: string}) // unused but required by Aggregate.Spec

  @schema
  type error = | TEAggNoError // unused but required by Aggregate.Spec
}

// ─────────────────────────────────────────────────────────────
// Mapping: Forward → Execute
// ─────────────────────────────────────────────────────────────

module ForwardMapping = {
  module Aggregate = TargetAggSpec

  let mapIncomingCommand = (
    _id: string,
    cmd: TestEPSpec.command,
    _meta: Reventless.Message.meta,
  ): array<Reventless.ExtensionPointMapping.commandAction<TargetAggSpec.command, TestEPSpec.directive>> =>
    switch cmd {
    | Forward({targetId}) =>
      let execCmd = TargetAggSpec.Execute({targetId: targetId})
      [Reventless.ExtensionPointMapping.PublishCommand(targetId, execCmd)]
    }

  let mapOutgoingEvent: option<
    Reventless.ExtensionPointMapping.mapOutgoingEvent<
      TargetAggSpec.event,
      TestEPSpec.event,
      TestEPSpec.directive,
    >,
  > = None
}

// ─────────────────────────────────────────────────────────────
// Pre-compiled mapping (Spec + Impl → T)
// ─────────────────────────────────────────────────────────────

module TestEPMapping1 = ReventlessCore.ExtensionPointMapping.Make(TestEPSpec, ForwardMapping)

// ─────────────────────────────────────────────────────────────
// Mappings collection satisfying ExtensionPoint.Mappings
// ─────────────────────────────────────────────────────────────

module TestEPMappings = {
  module Spec = TestEPSpec
  module type Mapping = Reventless.ExtensionPointMapping.T with module ExtensionPoint := TestEPSpec
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

let mockPublishFn: Reventless.CommandTopic.publishJsons = async cmds => {
  capturedCmds := capturedCmds.contents->Array.concat(cmds)
}

let mockQueryEngine: Reventless.QueryEngine.operations = {
  scan: async (~readModelName as _, ~filterConfigs as _, ~limit as _) => [],
  query: async (
    ~readModelName as _,
    ~key as _=?,
    ~id as _,
    ~subIdConfig as _=?,
    ~filterConfigs as _=?,
    ~ascending as _=?,
    ~limit as _=?,
  ) => [],
}

let mockScheduler: Reventless.Scheduler.operations = {
  createSchedule: async (_, _) => (),
  deleteSchedule: async (_, _) => (),
}

let mockResourceNaming: Reventless.ResourceNaming.operations = {
  validateName: n => n,
  urnName: n => n,
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

let testMeta: Reventless.Message.meta = {
  service: "TestEP",
  time: "2024-01-01T00:00:00.000Z",
  ip: "127.0.0.1",
  user: "testuser",
  msgId: "msg-001",
  correlationId: "corr-001",
}

let resetMocks = () => {
  capturedCmds := []
}
