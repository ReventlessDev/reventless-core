open ReventlessCore

// Test DSL for aggregate-style egress (`SideEffect.T`). Mirrors
// `OutboundTranslation_GWT` adapted to the SideEffect runtime contract: the
// unit under test is `SE.execute`, which returns `promise<unit>` and reaches
// external services through direct module imports. Option C of the
// `sideeffect-gwt` plan: the framework stays out of the import mechanics —
// per-service `*_Mock.res` modules own the recording state and surface it
// through this `mock` handle. The GWT runs `execute`, then reads the snapshot
// and renders assertions against captured calls.

// Polymorphic mock handle a test passes to `whenExecuted`. The mock module
// owns the recording state (a `ref<array<call>>` mutated as the SE calls the
// service); `snapshot` reads it; `encode` is used to render mismatched calls
// in failure messages.
type mock<'call> = {
  snapshot: unit => array<'call>,
  encode: 'call => JSON.t,
}

// Stub `QueryEngine.operations` used when a test doesn't pass its own.
// Returns empty result sets — enough for SEs that never query, which is the
// idiomatic shape.
let stubQueryEngine: Reventless.QueryEngine.operations = {
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

module type T = {
  module SE: Reventless.SideEffect.T

  let describe: (string, unit => unit) => unit
  let test: (string, ~timeout: int=?, unit => promise<Outcome.outcome>) => unit

  type input = {
    id: SE.Source.Id.t,
    meta: Message.meta,
    event: SE.Source.event,
  }

  // Post-execution state the pipeline carries forward. Holds the inputs (so
  // failure messages can quote them), the captured calls, and the encoder
  // (passed through from the mock) used to render them.
  type attempt<'call> = {
    input: input,
    captured: array<'call>,
    encode: 'call => JSON.t,
  }

  // given*
  let givenEvent: SE.Source.event => input
  let givenEventForId: (SE.Source.Id.t, SE.Source.event) => input
  let givenMeta: (input, Message.meta) => input

  // when — runs `SE.execute` against a stub QueryEngine (override via
  // ~queryEngine) and the supplied mock's snapshot. The mock module is
  // expected to install itself into the service it shadows BEFORE this is
  // called (the per-service `*_Mock.res` convention; see the example).
  let whenExecuted: (
    input,
    mock<'call>,
    ~queryEngine: Reventless.QueryEngine.operations=?,
  ) => promise<attempt<'call>>

  // then*
  let thenNoExternalCalls: promise<attempt<'call>> => promise<Outcome.outcome>
  let thenExternalCalls: (promise<attempt<'call>>, array<'call>) => promise<Outcome.outcome>
  let thenExternalCallCount: (promise<attempt<'call>>, int) => promise<Outcome.outcome>
}

module Make = (SE: Reventless.SideEffect.T): (T with module SE = SE) => {
  module SE = SE


  let describe = JestBind.describe
  let test = (name, ~timeout=?, body) =>
    JestBind.testPromise(~slice=SE.Source.name, name, ~timeout?, body)

  type input = {
    id: SE.Source.Id.t,
    meta: Message.meta,
    event: SE.Source.event,
  }

  type attempt<'call> = {
    input: input,
    captured: array<'call>,
    encode: 'call => JSON.t,
  }

  let defaultId = SE.Source.Id.makeFromString("test-id-1")
  let defaultMeta: Message.meta = {
    service: SE.Source.name,
    time: "2024-01-01T00:00:00Z",
    msgId: "test-msg-1",
    correlationId: "test-msg-1",
  }

  let givenEvent = event => {id: defaultId, meta: defaultMeta, event}
  let givenEventForId = (id, event) => {id, meta: defaultMeta, event}
  let givenMeta = (input, meta) => {...input, meta}

  let whenExecuted = async (input, mock, ~queryEngine=stubQueryEngine) => {
    await SE.execute(input.id, input.meta, input.event, queryEngine)
    {input, captured: mock.snapshot(), encode: mock.encode}
  }

  let encCalls = (calls, encode) => calls->Array.map(encode)

  let thenNoExternalCalls = async pending => {
    let {captured, encode, _} = await pending
    if captured == [] {
      Outcome.pass
    } else {
      Outcome.fail(NoEventExpected({actual: encCalls(captured, encode)}))
    }
  }

  let thenExternalCalls = async (pending, expected) => {
    let {captured, encode, _} = await pending
    if captured == expected {
      Outcome.pass
    } else {
      Outcome.fail(
        EventsMismatch({
          expected: encCalls(expected, encode),
          actual: encCalls(captured, encode),
        }),
      )
    }
  }

  let thenExternalCallCount = async (pending, expected) => {
    let {captured, _} = await pending
    let actual = Array.length(captured)
    if actual == expected {
      Outcome.pass
    } else {
      Outcome.fail(
        StateMismatch({
          key: "external-call-count",
          expected: Some(JSON.Encode.int(expected)),
          actual: Some(JSON.Encode.int(actual)),
        }),
      )
    }
  }
}
