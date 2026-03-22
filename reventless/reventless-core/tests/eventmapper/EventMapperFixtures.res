@@warning("-44")
open Reventless
open Reventless.Projection

S.enableJson()

// ─────────────────────────────────────────────────────────────
// Source event spec (aggregate events)
// ─────────────────────────────────────────────────────────────

module SourceSpec = {
  module Id = Reventless.Id.String
  let name = "SourceAggregate"

  @schema
  type event =
    | ItemCreated({name: string, price: float})
    | ItemPriceUpdated({newPrice: float})
    | ItemRemoved

  let moduleUrl: string = %raw(`import.meta.url`)
}

// ─────────────────────────────────────────────────────────────
// Target read model spec
// ─────────────────────────────────────────────────────────────

module TargetSpec = {
  module Id = Reventless.Id.String
  let name = "ItemCatalog"

  @schema
  type state = {name: string, price: float}

  let config = ReadModel.config()
  let subIdConfig = None
}

// ─────────────────────────────────────────────────────────────
// Mapping: SourceSpec events → TargetSpec projection actions
// ─────────────────────────────────────────────────────────────

module ItemMapping = Mapping.Make(
  SourceSpec,
  TargetSpec,
  {
    let map = (msg: Message.event'<string, SourceSpec.event>) =>
      switch msg.event {
      | ItemCreated({name, price}) => Create(msg.id, ({name, price}: TargetSpec.state))
      | ItemPriceUpdated({newPrice}) => Update(msg.id, s => {...s, price: newPrice})
      | ItemRemoved => Delete(msg.id)
      }
  },
)

// ─────────────────────────────────────────────────────────────
// Test metadata
// ─────────────────────────────────────────────────────────────

let testMeta: Message.meta = {
  service: "SourceAggregate",
  time: "2024-01-01T00:00:00.000Z",
  ip: "127.0.0.1",
  user: "testuser",
  msgId: "msg-001",
  correlationId: "corr-001",
}

let makeSourceEvent' = (id, event) => ({
  Message.id,
  meta: testMeta,
  event,
}: Message.event'<string, SourceSpec.event>)

// ─────────────────────────────────────────────────────────────
// EventMapper_Callback test fixtures
// Source → Target (event → command) mapping
// ─────────────────────────────────────────────────────────────

module CmdSourceSpec = {
  module Id = Reventless.Id.StringPure
  let name = "TestCmdSource"

  @schema
  type event =
    | OrderPlaced({orderId: string, amount: float})
    | OrderShipped({orderId: string})

  let moduleUrl: string = %raw(`import.meta.url`)
}

module CmdTargetSpec = {
  module Id = Reventless.Id.StringPure
  let name = "TestCmdTarget"

  @schema
  type command =
    | ProcessOrder({orderId: string, amount: float})
    | ShipOrder({orderId: string})

  let moduleUrl: string = %raw(`import.meta.url`)
}

// Publish mapping: OrderPlaced → ProcessOrder
module OrderMapping = {
  module Source = CmdSourceSpec
  module Target = CmdTargetSpec

  let map = (
    id: CmdSourceSpec.Id.t,
    event: CmdSourceSpec.event,
    _queryEngine,
  ): array<Reventless.EventMapping.action<CmdTargetSpec.Id.t, CmdTargetSpec.command>> =>
    switch event {
    | OrderPlaced({orderId, amount}) =>
      [Reventless.EventMapping.Publish(id, CmdTargetSpec.ProcessOrder({orderId, amount}))]
    | OrderShipped({orderId}) =>
      let cmd = CmdTargetSpec.ShipOrder({orderId: orderId})
      [Reventless.EventMapping.Publish(id, cmd)]
    }
}

// Counter mapping: OrderPlaced → Count action
module CountOrderMapping = {
  module Source = CmdSourceSpec
  module Target = CmdTargetSpec

  let map = (
    _id: CmdSourceSpec.Id.t,
    event: CmdSourceSpec.event,
    _queryEngine,
  ): array<Reventless.EventMapping.action<CmdTargetSpec.Id.t, CmdTargetSpec.command>> =>
    switch event {
    | OrderPlaced(_) => [Reventless.EventMapping.Count("order-counter")]
    | OrderShipped(_) =>
      [
        Reventless.EventMapping.AddToCounterTarget({
          counterId: "order-counter",
          target: 5,
        }),
      ]
    }
}

module OrderMappings: EventMapper.Mappings with module Target = CmdTargetSpec = {
  module Target = CmdTargetSpec
  module type Mapping = Reventless.EventMapping.T with module Target := CmdTargetSpec
  let moduleUrl: string = %raw(`import.meta.url`)
  let mappings: array<module(Mapping)> = [module(OrderMapping)]
  let counter = None
}

module CountOrderMappings: EventMapper.Mappings with module Target = CmdTargetSpec = {
  module Target = CmdTargetSpec
  module type Mapping = Reventless.EventMapping.T with module Target := CmdTargetSpec
  let moduleUrl: string = %raw(`import.meta.url`)
  let mappings: array<module(Mapping)> = [module(CountOrderMapping)]
  let counter = None
}

// ─────────────────────────────────────────────────────────────
// Shared mocks for EventMapper_Callback tests
// ─────────────────────────────────────────────────────────────

let capturedCmds: ref<array<Message.commandJson>> = ref([])
let capturedCountItems: ref<array<ReventlessInfra.Counter.countItem>> = ref([])
let capturedCounterTargets: ref<array<ReventlessInfra.Counter.counterTargetRef>> = ref([])

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

// CounterOps mock for MakeCounterHandler
module MockCounterOps: EventMapper_Callback.CounterOps = {
  let publishJsons: CommandTopic.publishJsons = async cmds => {
    capturedCmds := capturedCmds.contents->Array.concat(cmds)
  }
  let queryEngine = mockQueryEngine
}

// MakeCounterHandler under test
module TestCounterHandler = EventMapper_Callback.MakeCounterHandler(
  CmdTargetSpec,
  OrderMappings,
  MockCounterOps,
)

// configurable mock for commonEventsHandler — reassigned in each test
let mockCommonHandler: ref<
  array<JSON.t> => promise<(
    promise<array<Message.commandJson>>,
    array<ReventlessCore.Counter.action>,
  )>,
> = ref(async _ => (Promise.resolve([]), []))

let mockCountFailUntil = ref(0)
let mockCountCallCount = ref(0)

// EventCollectorOps mock for MakeEventCollectorHandler
module MockECOps: EventMapper_Callback.EventCollectorOps = {
  let publishJsons: CommandTopic.publishJsons = async cmds => {
    capturedCmds := capturedCmds.contents->Array.concat(cmds)
  }
  let count: ReventlessInfra.Counter.count = async items => {
    mockCountCallCount := mockCountCallCount.contents + 1
    capturedCountItems := capturedCountItems.contents->Array.concat(items)
    if mockCountCallCount.contents <= mockCountFailUntil.contents {
      JsError.throwWithMessage("count failed")
    }
  }
  let addToCounterTarget: ReventlessInfra.Counter.addToCounterTarget = async target => {
    capturedCounterTargets := capturedCounterTargets.contents->Array.concat([target])
  }
  let commonEventsHandler = async eventsJson' => {
    await mockCommonHandler.contents(eventsJson')
  }
}

// MakeEventCollectorHandler under test
module TestECHandler = EventMapper_Callback.MakeEventCollectorHandler(MockECOps)

let evtMapTestMeta: Message.meta = {
  service: CmdSourceSpec.name,
  time: "2024-01-01T00:00:00Z",
  ip: "127.0.0.1",
  user: "test-user",
  msgId: "test-msg-1",
  correlationId: "test-corr-1",
}

let makeEventJson = (~service=CmdSourceSpec.name, id, eventJson): JSON.t =>
  [
    ("id", JSON.Encode.string(id)),
    (
      "meta",
      {...evtMapTestMeta, service: service}->Message.encode(Message.metaSchema),
    ),
    ("event", eventJson),
  ]
  ->Dict.fromArray
  ->JSON.Encode.object

let resetMocks = () => {
  capturedCmds := []
  capturedCountItems := []
  capturedCounterTargets := []
  mockCountFailUntil := 0
  mockCountCallCount := 0
  mockCommonHandler := async _ => (Promise.resolve([]), [])
}
