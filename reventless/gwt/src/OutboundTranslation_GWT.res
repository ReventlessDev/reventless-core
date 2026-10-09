open ReventlessCore

// Minimal inline spec for the flat `Make`, which only mocks `translate`.
// `FromSlice` below runs the slice's own `translate` against capability fakes.
module type SliceSpec = {
  let name: string

  @schema
  type consumedEvent

  @schema
  type outboundItem

  @schema
  type inboundCommand

  let collect: (consumedEvent, ~sourceId: string) => array<(string, outboundItem)>
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

  type translateResult = result<option<(string, Spec.inboundCommand)>, string>

  // The state the pipeline carries after a translate attempt. `retries` counts
  // the number of failed re-attempts (0 for a single `whenTranslateMocked`).
  type attempt = {
    id: string,
    item: Spec.outboundItem,
    result: translateResult,
    retries: int,
  }

  // Unit — collect
  let givenEvent: Spec.consumedEvent => Spec.consumedEvent
  let whenCollect: (Spec.consumedEvent, ~sourceId: string=?) => array<(string, Spec.outboundItem)>
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
  // Re-invokes the mock on each `Error` up to `maxRetries` times (or until it
  // returns `Ok`), tracking how many retries were spent — the real counter
  // `thenRetryRecorded` asserts against.
  let whenTranslateRetrying: (
    (string, Spec.outboundItem),
    ~maxRetries: int,
    (string, Spec.outboundItem) => promise<translateResult>,
  ) => promise<attempt>
  let thenCommand: (promise<attempt>, string, Spec.inboundCommand) => promise<Outcome.outcome>
  let thenNoCommand: promise<attempt> => promise<Outcome.outcome>
  let thenRetryRecorded: (promise<attempt>, int) => promise<Outcome.outcome>
  let thenTodoStatus: (promise<attempt>, string, todoStatus) => promise<Outcome.outcome>
}

/** Deprecated: takes an adapter module with `collect` on the spec and never
    runs `translate`. Use `FromSlice`; this goes one release after the examples
    have moved. */
module Make = (Spec: SliceSpec): (T with module Spec = Spec) => {
  module Spec = Spec

  let describe = JestBind.describe
  let test = (name, ~timeout=?, body) =>
    JestBind.testPromise(~slice=Spec.name, name, ~timeout?, body)
  let testSync = (name, body) => JestBind.test(~slice=Spec.name, name, body)

  type translateResult = result<option<(string, Spec.inboundCommand)>, string>

  type attempt = {
    id: string,
    item: Spec.outboundItem,
    result: translateResult,
    retries: int,
  }

  let encItem = (i: Spec.outboundItem) => i->Message.encode(Spec.outboundItemSchema)
  let encItems = (arr: array<(string, Spec.outboundItem)>) =>
    arr->Array.map(((id, i)) => (id, encItem(i)))
  let encInbound = (c: Spec.inboundCommand) => c->Message.encode(Spec.inboundCommandSchema)

  // Unit: collect
  //
  // `~sourceId` defaults so a DCB-source test — whose event names its own subject
  // in the payload — reads exactly as it did before this argument existed. An
  // aggregate-source test passes the entity id it is exercising.
  let givenEvent = e => e
  let whenCollect = (e, ~sourceId="") => e->Spec.collect(~sourceId)
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
    {id, item, result, retries: 0}
  }

  let whenTranslateRetrying = async ((id, item), ~maxRetries, mock) => {
    let result = ref(await mock(id, item))
    let retries = ref(0)
    let failed = () =>
      switch result.contents {
      | Error(_) => true
      | Ok(_) => false
      }
    while failed() && retries.contents < maxRetries {
      retries := retries.contents + 1
      result := (await mock(id, item))
    }
    {id, item, result: result.contents, retries: retries.contents}
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
    | Error(msg) => Outcome.fail(TranslateError({expected: "(command)", actual: Some(msg)}))
    }
  }

  let thenNoCommand = async pending => {
    let {result, _} = await pending
    switch result {
    | Ok(None) => Outcome.pass
    | Ok(Some((id, cmd))) => Outcome.fail(NoEventExpected({actual: [commandPairJson(id, cmd)]}))
    | Error(msg) => Outcome.fail(TranslateError({expected: "(no command)", actual: Some(msg)}))
    }
  }

  // `thenRetryRecorded(n)` — asserts the harness spent exactly `n` retries.
  // Pair with `whenTranslateRetrying(~maxRetries)`, which re-invokes the mock on
  // each failure and tracks the count; a single `whenTranslateMocked` records 0.
  let thenRetryRecorded = async (pending, expectedRetries) => {
    let {retries, _} = await pending
    if retries == expectedRetries {
      Outcome.pass
    } else {
      Outcome.fail(
        StateMismatch({
          key: "retries",
          expected: Some(JSON.Encode.int(expectedRetries)),
          actual: Some(JSON.Encode.int(retries)),
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
    let actualStatus: todoStatus = switch result {
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

/** A to-do's status as the runtime leaves it after an attempt. `#Pending` is the
    older name for `#Failed`, kept for one release. */
type status = [#Completed | #Failed | #Abandoned | #Pending]

// The slice as written: its `Spec` and its `_Translation` body, run against
// recording capability fakes.
module FromSlice = (
  Spec: Reventless.OutboundTranslationSlice.Spec,
  Translation: Reventless.OutboundTranslationSlice.Translation with module Spec := Spec,
) => {
  let describe = JestBind.describe
  let test = (name, ~timeout=?, body) =>
    JestBind.testPromise(~slice=Spec.name, name, ~timeout?, body)
  let testSync = (name, body) => JestBind.test(~slice=Spec.name, name, body)

  type translateResult = result<option<(string, Spec.inboundCommand)>, string>

  type todo = {id: string, item: Spec.outboundItem, fakes: Capabilities_Fake.t}

  /** What one or more attempts left behind. `retries` is the row's
      `retryCount`: the attempts that failed. */
  type attempt = {
    id: string,
    item: Spec.outboundItem,
    result: translateResult,
    retries: int,
    status: status,
    sent: array<Capabilities_Fake.call>,
  }

  let encItems = (arr: array<(string, Spec.outboundItem)>) =>
    arr->Array.map(((id, i)) => (id, i->Message.encode(Spec.outboundItemSchema)))
  let commandPairJson = (id, cmd) => {
    let d = Dict.make()
    d->Dict.set("id", JSON.Encode.string(id))
    d->Dict.set("command", cmd->Message.encode(Spec.inboundCommandSchema))
    JSON.Encode.object(d)
  }
  let errorOf = exn =>
    switch exn {
    | S.Exn(e) => e.message
    | JsExn(e) => JsExn.message(e)->Option.getOr("unknown error")
    | _ => "unknown error"
    }

  // Unit: collect
  let givenEvent = (e: Spec.consumedEvent) => e
  let whenCollect = (e, ~sourceId="") => Translation.collect(e, ~sourceId)
  let thenTodos = (actual, expected) =>
    actual == expected
      ? Outcome.pass
      : Outcome.fail(TodoMismatch({expected: encItems(expected), actual: encItems(actual)}))

  // Unit: translate
  let givenTodo = (id, item) => {id, item, fakes: Capabilities_Fake.make()}
  /** Scripted capabilities for `givenCapabilities`; see `Capabilities_Fake.make`. */
  let fakes = Capabilities_Fake.make
  let givenCapabilities = (todo: todo, fakes) => {...todo, fakes}

  // One attempt, judged as the runtime judges it: a throw is a failure, and so
  // is a command its own schema cannot encode.
  let attemptWith = async (todo: todo, run) => {
    let result = try await run(todo.id, todo.item) catch {
    | exn => Error(errorOf(exn))
    }
    switch result {
    | Ok(Some((_, cmd))) =>
      switch cmd->Message.encode(Spec.inboundCommandSchema) {
      | _ => result
      | exception exn => Error(`failed to encode inbound command: ${errorOf(exn)}`)
      }
    | other => other
    }
  }

  // Attempts until one succeeds or `limit` have failed. The status is judged
  // against `maxRetries`, the runtime's budget: that many failures abandon a row.
  let attempts = async (todo: todo, ~limit, ~maxRetries, run) => {
    let result = ref(await attemptWith(todo, run))
    let failures = ref(Result.isError(result.contents) ? 1 : 0)
    while Result.isError(result.contents) && failures.contents < limit {
      result := (await attemptWith(todo, run))
      if Result.isError(result.contents) {
        failures := failures.contents + 1
      }
    }
    {
      id: todo.id,
      item: todo.item,
      result: result.contents,
      retries: failures.contents,
      status: switch result.contents {
      | Ok(_) => #Completed
      | Error(_) => failures.contents >= maxRetries ? #Abandoned : #Failed
      },
      sent: todo.fakes.calls(),
    }
  }

  /** One attempt of the slice's own `translate`, against the given capabilities. */
  let whenTranslated = (todo: todo) =>
    attempts(todo, ~limit=1, ~maxRetries=Spec.maxRetries, (id, item) =>
      Translation.translate(id, item, ~capabilities=todo.fakes.capabilities)
    )
  /** One attempt, answered by `mock` instead of `translate`. */
  let whenTranslateMocked = (todo, mock) =>
    attempts(todo, ~limit=1, ~maxRetries=Spec.maxRetries, mock)
  /** Attempts as the sweeps would make them: until one succeeds or `maxRetries`
      (the Spec's, unless given) have failed. */
  let whenTranslateRetrying = (todo, ~maxRetries=Spec.maxRetries, mock) =>
    attempts(todo, ~limit=maxRetries, ~maxRetries, mock)

  /** The budget is spent: what `onExhausted` publishes, if anything. */
  let whenExhausted = async (todo: todo, ~lastError=?) => {
    id: todo.id,
    item: todo.item,
    result: Ok(Translation.onExhausted(todo.id, todo.item, ~lastError)),
    retries: Spec.maxRetries,
    status: #Abandoned,
    sent: [],
  }

  let thenCommand = async (pending, expectedId, expectedCmd) => {
    let {result, _} = await pending
    switch result {
    | Ok(Some((id, cmd))) if id == expectedId && cmd == expectedCmd => Outcome.pass
    | Ok(actual) =>
      Outcome.fail(
        EventsMismatch({
          expected: [commandPairJson(expectedId, expectedCmd)],
          actual: actual->Option.mapOr([], ((id, cmd)) => [commandPairJson(id, cmd)]),
        }),
      )
    | Error(msg) => Outcome.fail(TranslateError({expected: "(command)", actual: Some(msg)}))
    }
  }

  let thenNoCommand = async pending => {
    let {result, _} = await pending
    switch result {
    | Ok(None) => Outcome.pass
    | Ok(Some((id, cmd))) => Outcome.fail(NoEventExpected({actual: [commandPairJson(id, cmd)]}))
    | Error(msg) => Outcome.fail(TranslateError({expected: "(no command)", actual: Some(msg)}))
    }
  }

  let thenSent = async (pending, expected: array<Capabilities_Fake.call>) => {
    let {sent, _} = await pending
    sent == expected
      ? Outcome.pass
      : Outcome.fail(
          EventsMismatch({
            expected: expected->Array.map(Capabilities_Fake.toJson),
            actual: sent->Array.map(Capabilities_Fake.toJson),
          }),
        )
  }
  let thenNothingSent = pending => thenSent(pending, [])

  let thenRetryRecorded = async (pending, expectedRetries) => {
    let {retries, _} = await pending
    retries == expectedRetries
      ? Outcome.pass
      : Outcome.fail(
          StateMismatch({
            key: "retries",
            expected: Some(JSON.Encode.int(expectedRetries)),
            actual: Some(JSON.Encode.int(retries)),
          }),
        )
  }

  let statusName = (s: status) =>
    switch s {
    | #Completed => "#Completed"
    | #Failed | #Pending => "#Failed"
    | #Abandoned => "#Abandoned"
    }

  let thenTodoStatus = async (pending, expectedId, expectedStatus: status) => {
    let {id, status, _} = await pending
    if id == expectedId && statusName(status) == statusName(expectedStatus) {
      Outcome.pass
    } else {
      let encOne = (rid, s) =>
        JSON.Encode.object(
          Dict.fromArray([
            ("id", JSON.Encode.string(rid)),
            ("status", JSON.Encode.string(statusName(s))),
          ]),
        )
      Outcome.fail(
        StateMismatch({
          key: id,
          expected: Some(encOne(expectedId, expectedStatus)),
          actual: Some(encOne(id, status)),
        }),
      )
    }
  }
}
