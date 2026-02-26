S.enableJson()

// ─────────────────────────────────────────────────────────────
// Event source spec for SideEffect
// ─────────────────────────────────────────────────────────────

module TestSource = {
  module Id = Reventless.Id.StringPure
  let name = "TestSideEffectSource"

  @schema
  type event = | SomethingHappened({value: string})
}

// ─────────────────────────────────────────────────────────────
// Captures
// ─────────────────────────────────────────────────────────────

type executeCall = {id: string, event: TestSource.event}

let capturedExecuteCalls: ref<array<executeCall>> = ref([])
let executeThrowOnCall = ref(0)  // throw on this call number (1-based); 0 = never throw
let executeCallCount = ref(0)

// ─────────────────────────────────────────────────────────────
// SideEffect module
// ─────────────────────────────────────────────────────────────

module TestSideEffect: Reventless.SideEffect.T = {
  module Source = TestSource

  let execute = async (id, _meta, event, _queryEngine) => {
    executeCallCount := executeCallCount.contents + 1
    if executeThrowOnCall.contents > 0 && executeCallCount.contents == executeThrowOnCall.contents {
      JsError.throwWithMessage("side effect failed")
    }
    capturedExecuteCalls :=
      capturedExecuteCalls.contents->Array.concat([
        {id: id->TestSource.Id.toString, event},
      ])
  }
}

// ─────────────────────────────────────────────────────────────
// SideEffectHandler_Callback spec and handler under test
// ─────────────────────────────────────────────────────────────

module TestSpec: SideEffectHandler_Callback.Spec = {
  let sideEffects: array<module(Reventless.SideEffect.T)> = [module(TestSideEffect)]
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
}

module TestHandler = SideEffectHandler_Callback.Make(TestSpec)

// ─────────────────────────────────────────────────────────────
// Test helpers
// ─────────────────────────────────────────────────────────────

let testMeta: Message.meta = {
  service: TestSource.name,
  time: "2024-01-01T00:00:00Z",
  ip: "127.0.0.1",
  user: "test-user",
  msgId: "se-msg-1",
  correlationId: "se-corr-1",
}

let makeEventJson = (~service=TestSource.name, id, event): JSON.t =>
  [
    ("id", JSON.Encode.string(id)),
    (
      "meta",
      {...testMeta, service: service}->Message.encode(Message.metaSchema),
    ),
    ("event", event->Message.encode(TestSource.eventSchema)),
  ]
  ->Dict.fromArray
  ->JSON.Encode.object

let reset = () => {
  capturedExecuteCalls := []
  executeThrowOnCall := 0
  executeCallCount := 0
}
