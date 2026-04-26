open ReventlessCore

// Minimal inline spec — parallels the pattern in Behavior_GWT so that sury-ppx
// processes the @schema attributes in this compilation unit. Matches the
// relevant subset of `Reventless.StateChangeSlice.MergedSpec`.
module type SliceSpec = {
  let name: string

  type state
  let initialState: state

  @schema
  type consumedEvent

  let evolve: (state, consumedEvent) => state

  @schema
  type command

  @schema
  type error

  @schema
  type event

  let decide: (state, command) => result<array<event>, error>
}

module type T = {
  module Spec: SliceSpec

  let describe: (string, unit => unit) => unit
  let test: (string, unit => Outcome.outcome) => unit

  let givenEvents: array<Spec.consumedEvent> => array<Spec.consumedEvent>

  let whenCmd: (array<Spec.consumedEvent>, Spec.command) => array<Spec.event>

  let thenEvent: (array<Spec.event>, Spec.event) => Outcome.outcome
  let thenEvents: (array<Spec.event>, array<Spec.event>) => Outcome.outcome
  let thenNoEvent: array<Spec.event> => Outcome.outcome
  let thenEventWithError: (array<Spec.event>, Spec.event, Spec.error) => Outcome.outcome
  let thenEventsWithError: (array<Spec.event>, array<Spec.event>, Spec.error) => Outcome.outcome
  let thenError: (array<Spec.event>, Spec.error) => Outcome.outcome

  // Stage 4 — DCB optimistic-concurrency contract.
  //
  // `thenAppendsConditionedOn(query)` documents the DCB query the slice's
  // runtime would emit for the previously-exercised command. It auto-derives
  // the query via the same helpers the runtime uses and fails with
  // `AppendConditionMismatch` if the dev's literal disagrees.
  //
  // `thenAppendsConditionedOnExactly(condition)` asserts the full
  // `DcbTag.appendCondition` (including `after` position if any). Bypasses
  // the implicit "missing `@s.matches(DcbTag.string)`" check so that slices
  // with genuinely no tagged fields can still document their condition.
  let thenAppendsConditionedOn: (
    array<Spec.event>,
    Reventless.DcbTag.query,
  ) => Outcome.outcome
  let thenAppendsConditionedOnExactly: (
    array<Spec.event>,
    Reventless.DcbTag.appendCondition,
  ) => Outcome.outcome
}

// JSON encoder for `Reventless.DcbTag.appendCondition`. The framework doesn't
// ship a sury schema for it, so we encode structurally to keep the Outcome
// algebra's JSON payload closed (no opaque ReScript values leak through).
let encodeTag = (t: Reventless.DcbTag.tag): JSON.t => {
  let d = Dict.make()
  d->Dict.set("key", JSON.Encode.string(t.key))
  d->Dict.set("value", JSON.Encode.string(t.value))
  JSON.Encode.object(d)
}

let encodeQueryItem = (qi: Reventless.DcbTag.queryItem): JSON.t => {
  let d = Dict.make()
  switch qi.eventTypes {
  | Some(types) =>
    d->Dict.set("eventTypes", types->Array.map(JSON.Encode.string)->JSON.Encode.array)
  | None => ()
  }
  switch qi.tags {
  | Some(tags) => d->Dict.set("tags", tags->Array.map(encodeTag)->JSON.Encode.array)
  | None => ()
  }
  JSON.Encode.object(d)
}

let encodeQuery = (q: Reventless.DcbTag.query): JSON.t =>
  q->Array.map(encodeQueryItem)->JSON.Encode.array

let encodeAppendCondition = (c: Reventless.DcbTag.appendCondition): JSON.t => {
  let d = Dict.make()
  d->Dict.set("query", encodeQuery(c.query))
  switch c.after {
  | Some(pos) => d->Dict.set("after", JSON.Encode.string(pos))
  | None => ()
  }
  JSON.Encode.object(d)
}

module Make = (Spec: SliceSpec): (T with module Spec = Spec) => {
  module Spec = Spec

  S.enableJson()

  let describe = JestBind.describe
  let test = (name, body) => JestBind.test(~slice=Spec.name, name, body)

  let currentState = consumed =>
    consumed->Array.reduce(Spec.initialState, Spec.evolve)

  let errors = ref([])

  // Stage 4 — stashed DCB append condition derived inside `whenCmd`.
  // `None` until the first `whenCmd` runs.
  let derivedCondition: ref<option<Reventless.DcbTag.appendCondition>> = ref(None)

  // Stage 4 — implicit pending failure. Set by `whenCmd` when the derived
  // query carries zero tags across every clause AND the slice consumes at
  // least one event type — a strong signal that a `@s.matches(DcbTag.string)`
  // annotation is missing from the command schema. Regular `then*` combinators
  // surface it before their own checks; `thenAppendsConditionedOn*` bypass it
  // since the dev has opted into documenting the condition explicitly.
  let appendConditionFailure: ref<option<Outcome.mismatch>> = ref(None)

  // Same derivation path the slice's runtime uses — handles payload-less
  // consumed event variants that `DcbTag.extractVariantNames` skips.
  let consumedEventTypes = Reventless.DcbDecode.makeDecoder(Spec.consumedEventSchema).eventTypes

  let queryTagsTotal = (q: Reventless.DcbTag.query): int =>
    q->Array.reduce(0, (acc, qi) =>
      acc + qi.tags->Option.mapOr(0, t => t->Array.length)
    )

  let exec = (history, command): array<Spec.event> => {
    errors := []
    appendConditionFailure := None

    let query = Reventless.DcbTag.buildQueryFromCommand(
      ~eventTypes=consumedEventTypes,
      ~schema=Spec.commandSchema,
      ~value=command,
    )
    let condition: Reventless.DcbTag.appendCondition = {query: query}
    derivedCondition := Some(condition)

    if consumedEventTypes->Array.length > 0 && queryTagsTotal(query) == 0 {
      appendConditionFailure :=
        Some(
          Outcome.AppendConditionMismatch({
            expected: JSON.Encode.string(
              "a non-empty tag set derived from @s.matches(DcbTag.string) fields on the command",
            ),
            actual: encodeAppendCondition(condition),
          }),
        )
    }

    let state = currentState(history)
    switch Spec.decide(state, command) {
    | Ok(events) => events
    | Error(error) =>
      errors := [error]
      []
    }
  }

  let givenEvents = consumed => consumed
  let whenCmd = (history, cmd) => history->exec(cmd)

  let encEvent = (e: Spec.event) => e->Message.encode(Spec.eventSchema)
  let encEvents = evs => evs->Array.map(encEvent)
  let encError = (err: Spec.error) => err->Message.encode(Spec.errorSchema)

  // Every regular `then*` runs this first so the implicit append-condition
  // check surfaces before the assertion would report a downstream symptom.
  let checkAppendCondition = (): option<Outcome.outcome> =>
    appendConditionFailure.contents->Option.map(m => Outcome.fail(m))

  let unexpectedError = (events: array<Spec.event>): Outcome.outcome => {
    let actual = errors.contents->Array.get(0)->Option.map(encError)
    Outcome.fail(
      ErrorMismatch({
        expected: JSON.Encode.null,
        actual,
        actualEvents: events->encEvents,
      }),
    )
  }

  let thenEvents = (events, expectedEvents) =>
    switch checkAppendCondition() {
    | Some(o) => o
    | None =>
      if errors.contents->Array.length > 0 {
        unexpectedError(events)
      } else if events == expectedEvents {
        Outcome.pass
      } else {
        Outcome.fail(
          EventsMismatch({expected: expectedEvents->encEvents, actual: events->encEvents}),
        )
      }
    }

  let thenEvent = (events, expectedEvent) => thenEvents(events, [expectedEvent])

  let thenNoEvent = events =>
    switch checkAppendCondition() {
    | Some(o) => o
    | None =>
      if errors.contents->Array.length > 0 {
        unexpectedError(events)
      } else if events->Array.length == 0 {
        Outcome.pass
      } else {
        Outcome.fail(NoEventExpected({actual: events->encEvents}))
      }
    }

  let matchesError = (
    events: array<Spec.event>,
    expectedEvents: array<Spec.event>,
    expectedError: Spec.error,
  ): Outcome.outcome => {
    let expectedErrorJson = encError(expectedError)
    switch errors.contents->Array.get(0) {
    | None =>
      Outcome.fail(
        ErrorMismatch({
          expected: expectedErrorJson,
          actual: None,
          actualEvents: events->encEvents,
        }),
      )
    | Some(actual) if actual != expectedError =>
      Outcome.fail(
        ErrorMismatch({
          expected: expectedErrorJson,
          actual: Some(encError(actual)),
          actualEvents: events->encEvents,
        }),
      )
    | Some(_) =>
      if events == expectedEvents {
        Outcome.pass
      } else {
        Outcome.fail(
          EventsMismatch({expected: expectedEvents->encEvents, actual: events->encEvents}),
        )
      }
    }
  }

  let thenError = (events, expectedError) =>
    switch checkAppendCondition() {
    | Some(o) => o
    | None => matchesError(events, [], expectedError)
    }

  let thenEventWithError = (events, expectedEvent, expectedError) =>
    switch checkAppendCondition() {
    | Some(o) => o
    | None => matchesError(events, [expectedEvent], expectedError)
    }

  let thenEventsWithError = (events, expectedEvents, expectedError) =>
    switch checkAppendCondition() {
    | Some(o) => o
    | None => matchesError(events, expectedEvents, expectedError)
    }

  let thenAppendsConditionedOn = (_events, expectedQuery: Reventless.DcbTag.query) =>
    switch derivedCondition.contents {
    | None =>
      Outcome.fail(
        Throw({
          error: "thenAppendsConditionedOn: whenCmd must be called before this assertion",
          stack: "",
        }),
      )
    | Some(cond) =>
      if cond.query == expectedQuery {
        Outcome.pass
      } else {
        Outcome.fail(
          AppendConditionMismatch({
            expected: encodeAppendCondition({query: expectedQuery}),
            actual: encodeAppendCondition(cond),
          }),
        )
      }
    }

  let thenAppendsConditionedOnExactly = (
    _events,
    expectedCondition: Reventless.DcbTag.appendCondition,
  ) =>
    switch derivedCondition.contents {
    | None =>
      Outcome.fail(
        Throw({
          error: "thenAppendsConditionedOnExactly: whenCmd must be called before this assertion",
          stack: "",
        }),
      )
    | Some(cond) =>
      if cond == expectedCondition {
        Outcome.pass
      } else {
        Outcome.fail(
          AppendConditionMismatch({
            expected: encodeAppendCondition(expectedCondition),
            actual: encodeAppendCondition(cond),
          }),
        )
      }
    }
}
