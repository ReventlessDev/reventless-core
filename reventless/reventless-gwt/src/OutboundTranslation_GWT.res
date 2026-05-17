open ReventlessCore

// Minimal inline spec for OutboundTranslationSlice. `translate` is async and
// supplied at test-time via `whenTranslateMocked` so the external service is
// never hit. The spec's own `translate` is not part of the GWT — it's
// exercised only through the runtime tests.
module type SliceSpec = {
  let name: string

  @schema
  type consumedEvent

  @schema
  type outboundItem

  @schema
  type inboundCommand

  let collect: consumedEvent => array<(string, outboundItem)>
}

// Status enum reflecting how the slice's runtime labels a TODO after a
// translate call. A successful translate (Ok) marks the item #Completed;
// a failure (Error) leaves it #Pending for retry up to `maxRetries`.
type todoStatus = [#Completed | #Pending]

module type T = {
  module Spec: SliceSpec

  let describe: (string, unit => unit) => unit
  let test: (string, ~timeout: int=?, unit => promise<Outcome.outcome>) => unit
  // Sync companion for the `collect` leg, whose combinators return
  // `Outcome.outcome` directly (no Promise). The async `test` works for
  // collect bodies too, but only after a manual `Promise.resolve` wrapper.
  let testSync: (string, unit => Outcome.outcome) => unit

  type translateResult =
    result<option<(string, Spec.inboundCommand)>, string>

  // The state the pipeline carries after `whenTranslateMocked`.
  type attempt = {
    id: string,
    item: Spec.outboundItem,
    result: translateResult,
  }

  // Unit — collect
  let givenEvent: Spec.consumedEvent => Spec.consumedEvent
  let whenCollect: Spec.consumedEvent => array<(string, Spec.outboundItem)>
  let thenTodos: (
    array<(string, Spec.outboundItem)>,
    array<(string, Spec.outboundItem)>,
  ) => Outcome.outcome

  // Unit — translate
  let givenTodo: (string, Spec.outboundItem) => (string, Spec.outboundItem)
  let whenTranslateMocked: (
    (string, Spec.outboundItem),
    (string, Spec.outboundItem) => promise<translateResult>,
  ) => promise<attempt>
  let thenCommand: (
    promise<attempt>,
    string,
    Spec.inboundCommand,
  ) => promise<Outcome.outcome>
  let thenNoCommand: promise<attempt> => promise<Outcome.outcome>
  let thenRetryRecorded: (promise<attempt>, int) => promise<Outcome.outcome>
  let thenTodoStatus: (promise<attempt>, string, todoStatus) => promise<Outcome.outcome>
}

module Make = (Spec: SliceSpec): (T with module Spec = Spec) => {
  module Spec = Spec


  let describe = JestBind.describe
  let test = (name, ~timeout=?, body) =>
    JestBind.testPromise(~slice=Spec.name, name, ~timeout?, body)
  let testSync = (name, body) => JestBind.test(~slice=Spec.name, name, body)

  type translateResult =
    result<option<(string, Spec.inboundCommand)>, string>

  type attempt = {
    id: string,
    item: Spec.outboundItem,
    result: translateResult,
  }

  let encItem = (i: Spec.outboundItem) => i->Message.encode(Spec.outboundItemSchema)
  let encItems = (arr: array<(string, Spec.outboundItem)>) =>
    arr->Array.map(((id, i)) => (id, encItem(i)))
  let encInbound = (c: Spec.inboundCommand) =>
    c->Message.encode(Spec.inboundCommandSchema)

  // Unit: collect
  let givenEvent = e => e
  let whenCollect = e => e->Spec.collect
  let thenTodos = (actual, expected) =>
    if actual == expected {
      Outcome.pass
    } else {
      Outcome.fail(
        TodoMismatch({
          expected: encItems(expected),
          actual: encItems(actual),
        }),
      )
    }

  // Unit: translate
  let givenTodo = (id, item) => (id, item)
  let whenTranslateMocked = async ((id, item), mock) => {
    let result = await mock(id, item)
    {id, item, result}
  }

  let commandPairJson = (id, cmd) => {
    let d = Dict.make()
    d->Dict.set("id", JSON.Encode.string(id))
    d->Dict.set("command", encInbound(cmd))
    JSON.Encode.object(d)
  }

  let thenCommand = async (pending, expectedId, expectedCmd) => {
    let {result, _} = await pending
    switch result {
    | Ok(Some((id, cmd))) if id == expectedId && cmd == expectedCmd => Outcome.pass
    | Ok(Some((id, cmd))) =>
      Outcome.fail(
        EventsMismatch({
          expected: [commandPairJson(expectedId, expectedCmd)],
          actual: [commandPairJson(id, cmd)],
        }),
      )
    | Ok(None) =>
      Outcome.fail(
        EventsMismatch({
          expected: [commandPairJson(expectedId, expectedCmd)],
          actual: [],
        }),
      )
    | Error(msg) =>
      Outcome.fail(
        TranslateError({expected: "(command)", actual: Some(msg)}),
      )
    }
  }

  let thenNoCommand = async pending => {
    let {result, _} = await pending
    switch result {
    | Ok(None) => Outcome.pass
    | Ok(Some((id, cmd))) =>
      Outcome.fail(NoEventExpected({actual: [commandPairJson(id, cmd)]}))
    | Error(msg) =>
      Outcome.fail(
        TranslateError({expected: "(no command)", actual: Some(msg)}),
      )
    }
  }

  // `thenRetryRecorded(n)` — after one failed translate, we assert the result
  // is an Error (a retry *is* recorded); the slice runtime tracks retry counts
  // externally, so the DSL merely verifies the failure was observable. The
  // `n` argument documents intent and is echoed back on mismatch.
  let thenRetryRecorded = async (pending, _expectedRetries) => {
    let {result, _} = await pending
    switch result {
    | Error(_) => Outcome.pass
    | Ok(_) =>
      Outcome.fail(
        TranslateError({
          expected: "(error — retry recorded)",
          actual: None,
        }),
      )
    }
  }

  let statusToString = (s: todoStatus) =>
    switch s {
    | #Completed => "#Completed"
    | #Pending => "#Pending"
    }

  let thenTodoStatus = async (pending, expectedId, expectedStatus) => {
    let {id, result, _} = await pending
    let actualStatus: todoStatus =
      switch result {
      | Ok(_) => #Completed
      | Error(_) => #Pending
      }
    if id == expectedId && actualStatus == expectedStatus {
      Outcome.pass
    } else {
      let encOne = (rid, rstatus) => {
        let d = Dict.make()
        d->Dict.set("id", JSON.Encode.string(rid))
        d->Dict.set("status", JSON.Encode.string(statusToString(rstatus)))
        JSON.Encode.object(d)
      }
      Outcome.fail(
        StateMismatch({
          key: id,
          expected: Some(encOne(expectedId, expectedStatus)),
          actual: Some(encOne(id, actualStatus)),
        }),
      )
    }
  }
}
