// Fixtures for ExtensionPoint callback unit tests.
S.enableJson()

// ─────────────────────────────────────────────────────────────
// ExtensionPoint spec (command + directive types)
// ─────────────────────────────────────────────────────────────

// No explicit module type annotation — sealing hides constructors
module TestEPSpec = {
  let name = "TestExtensionPoint"

  @schema
  type command =
    | RouteToAgg({aggId: string})
    | CallHandler({value: string})

  @schema
  type event = | Done({result: string})

  @schema
  type directive = | DirectiveA
}

// ─────────────────────────────────────────────────────────────
// Shared captures
// ─────────────────────────────────────────────────────────────

let capturedPublishedCmds: ref<array<Message.commandJson>> = ref([])
let capturedCallCount = ref(0)

// ─────────────────────────────────────────────────────────────
// Mapping: routes commands to aggregate or direct handler
// ─────────────────────────────────────────────────────────────

module TestMapping = {
  module ExtensionPoint = TestEPSpec
  let aggregateName = "TestTargetAgg"

  let mapIncomingCommands = (
    topicItems: array<
      CommandTopic.topicItem<Message.command'<Reventless.Id.String.t, TestEPSpec.command>>,
    >,
    _createSchedule: Reventless.Schedule.create,
    _deleteSchedule: Reventless.Schedule.delete,
    _queryEngine: Reventless.QueryEngine.operations,
  ): array<ReventlessInfra.ExtensionPointMapping.abstractCommandAction> =>
    topicItems->Array.flatMap(topicItem =>
      switch topicItem.command.command {
      | TestEPSpec.RouteToAgg({aggId}) => [
          ReventlessInfra.ExtensionPointMapping.AbstractPublishCommand(
            "TestTargetAgg",
            topicItem.reference,
            {
              id: aggId,
              meta: topicItem.command.meta,
              commandJson: JSON.Encode.string("Create"),
            },
          ),
        ]
      | TestEPSpec.CallHandler(_) => [
          ReventlessInfra.ExtensionPointMapping.AbstractCall(
            topicItem.reference,
            async () => {
              capturedCallCount := capturedCallCount.contents + 1
            },
          ),
        ]
      }
    )

  let mapOutgoingEvent: option<
    (
      JSON.t,
      Reventless.Schedule.create,
      Reventless.Schedule.delete,
      Reventless.QueryEngine.operations,
    ) => array<
      ReventlessInfra.ExtensionPointMapping.abstractEventAction<TestEPSpec.event>,
    >,
  > = None
}

// ─────────────────────────────────────────────────────────────
// Mappings module for ExtensionPoint_Callback
// ─────────────────────────────────────────────────────────────

module TestMappings = {
  module Spec = TestEPSpec
  module type Mapping = ReventlessInfra.ExtensionPointMapping.T with module ExtensionPoint := TestEPSpec
  let mappings: array<module(Mapping)> = [module(TestMapping)]
}

// ─────────────────────────────────────────────────────────────
// Callback Spec (infrastructure mocks)
// ─────────────────────────────────────────────────────────────

module TestCallbackSpec: ExtensionPoint_Callback.Spec = {
  let publishToAggregates: dict<CommandTopic.publishJsons> =
    Dict.fromArray([
      (
        "TestTargetAgg",
        async cmds => {
          capturedPublishedCmds :=
            capturedPublishedCmds.contents->Array.concat(cmds)
        },
      ),
    ])

  let commandTopicResources: array<Adapter.resolvedResource> = []

  let scheduler: ReventlessInfra.Scheduler.operations = {
    createSchedule: async (_resources, _schedule) => (),
    deleteSchedule: async (_resources, _name) => (),
  }

  let queryEngine: Reventless.QueryEngine.operations = {
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

  let resourceNaming: ReventlessInfra.ResourceNaming.operations = {
    validateName: name => name,
    urnName: name => name,
  }
}

// ─────────────────────────────────────────────────────────────
// Handler under test
// ─────────────────────────────────────────────────────────────

module TestHandler = ExtensionPoint_Callback.Make(TestCallbackSpec, TestEPSpec, TestMappings)

// ─────────────────────────────────────────────────────────────
// Test helpers
// ─────────────────────────────────────────────────────────────

let testMeta: Message.meta = {
  service: "TestExtensionPoint",
  time: "2024-01-01T00:00:00Z",
  ip: "127.0.0.1",
  user: "test-user",
  msgId: "ep-msg-1",
  correlationId: "ep-corr-1",
}

let makeTopicItem = (
  reference,
  command,
): CommandTopic.topicItem<Message.command'<Reventless.Id.String.t, TestEPSpec.command>> => {
  command: {
    id: reference->Reventless.Id.String.makeFromString,
    meta: testMeta,
    command,
  },
  reference,
}

let reset = () => {
  capturedPublishedCmds := []
  capturedCallCount := 0
}
