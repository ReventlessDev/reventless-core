open ReventlessCore

// Plan 02 Phase 6b — unified Behavior GWT DSL covering both Aggregate and
// StateChangeSlice. Two entry points:
//
//   * [Make(Spec, Behavior)]              — StateChangeSlice form. [Spec] carries
//                                            [consumedEvent]; [Behavior.evolve]
//                                            consumes it. DCB append-condition
//                                            checks are wired in.
//   * [MakeFromAggregate(Spec, Behavior)] — Aggregate adapter. [Spec] is
//                                            [Reventless.Aggregate.Spec],
//                                            [Behavior] is [Reventless.Behavior.T].
//                                            No DCB semantics; the simpler
//                                            [AggregateT] surface is returned.
//
// Both produce the same [describe / test / givenEvents / whenCmd / then*]
// triple-A surface. Slice form additionally exposes
// [thenAppendsConditionedOn / thenAppendsConditionedOnExactly] for DCB
// optimistic-concurrency assertions.
//
// Aggregate users *cannot* use [Make] (their Spec doesn't carry [consumedEvent])
// and slice users *cannot* use [MakeFromAggregate] (their Spec/Behavior shape
// differs). Pick the matching entry point.

// ---------------------------------------------------------------------------
// Slice form — replaces the legacy `StateChangeSlice_GWT`.
// ---------------------------------------------------------------------------

module type BehaviorSpec = {
  let name: string

  @schema
  type consumedEvent

  @schema
  type command

  @schema
  type error

  @schema
  type event
}

module type Behavior = {
  module Spec: BehaviorSpec

  type state
  let initialState: state
  let evolve: (state, Spec.consumedEvent) => state
  let decide: (state, Spec.command) => result<array<Spec.event>, Spec.error>
}

module type T = {
  module Spec: BehaviorSpec

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

  // DCB optimistic-concurrency assertions.
  let thenAppendsConditionedOn: (
    array<Spec.event>,
    Reventless.DcbTag.query,
  ) => Outcome.outcome
  let thenAppendsConditionedOnExactly: (
    array<Spec.event>,
    Reventless.DcbTag.appendCondition,
  ) => Outcome.outcome
}

// JSON encoder for [Reventless.DcbTag.appendCondition]. The framework
// doesn't ship a sury schema for it; encoding structurally keeps the
// Outcome algebra's JSON payload closed.
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

module Make = (
  Spec: BehaviorSpec,
  Behavior: Behavior with module Spec := Spec,
): (T with module Spec = Spec) => {
  module Spec = Spec

  S.enableJson()

  let describe = JestBind.describe
  let test = (name, body) => JestBind.test(~slice=Spec.name, name, body)

  let currentState = consumed =>
    consumed->Array.reduce(Behavior.initialState, Behavior.evolve)

  let errors = ref([])

  // DCB append-condition derived inside [whenCmd]; [None] until first call.
  let derivedCondition: ref<option<Reventless.DcbTag.appendCondition>> = ref(None)

  // Implicit pending failure raised when the derived query carries zero tags
  // across every clause AND the slice consumes at least one event type — a
  // strong signal that a [@s.matches(DcbTag.string)] annotation is missing
  // from the command schema. Regular [then*] combinators surface it before
  // their own checks; [thenAppends*] bypass it.
  let appendConditionFailure: ref<option<Outcome.mismatch>> = ref(None)

  let consumedEventTypes =
    Reventless.DcbDecode.makeDecoder(Spec.consumedEventSchema).eventTypes

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
    switch Behavior.decide(state, command) {
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

// ---------------------------------------------------------------------------
// Aggregate adapter — preserves the legacy Aggregate-flavor surface.
// ---------------------------------------------------------------------------

// Minimal aggregate spec the DSL requires. Declared inline (rather than
// aliasing `Reventless.Behavior.T`'s inner Spec) because that inner Spec
// only carries the three @schema types — no `name` — and ReScript's
// `with module Spec = X` can only equate the inner Spec to a concrete
// module, not constrain it to a module type that adds `name`.
module type AggregateSpec = {
  let name: string
  @schema
  type command
  @schema
  type event
  @schema
  type error
}

module type AggregateT = {
  module Spec: AggregateSpec

  let describe: (string, unit => unit) => unit
  let test: (string, unit => Outcome.outcome) => unit

  let givenEvents: array<Spec.event> => array<Spec.event>

  let whenCmd: (array<Spec.event>, Spec.command) => array<Spec.event>

  let thenEvent: (array<Spec.event>, Spec.event) => Outcome.outcome
  let thenCompareEvent: (
    array<Spec.event>,
    Spec.event,
    (Spec.event, Spec.event) => bool,
  ) => Outcome.outcome
  let thenNoEvent: array<Spec.event> => Outcome.outcome
  let thenEventWithError: (array<Spec.event>, Spec.event, Spec.error) => Outcome.outcome
  let thenEvents: (array<Spec.event>, array<Spec.event>) => Outcome.outcome
  let thenCompareEvents: (
    array<Spec.event>,
    array<Spec.event>,
    (Spec.event, Spec.event) => bool,
  ) => Outcome.outcome
  let thenEventsWithError: (array<Spec.event>, array<Spec.event>, Spec.error) => Outcome.outcome
  let thenError: (array<Spec.event>, Spec.error) => Outcome.outcome
}

module MakeFromAggregate = (
  Spec: AggregateSpec,
  Behavior: Behavior.T with module Spec = Spec,
): (AggregateT with module Spec = Spec) => {
  module Spec = Spec

  S.enableJson()

  let describe = JestBind.describe
  let test = (name, body) => JestBind.test(~slice=Spec.name, name, body)

  let currentState = events =>
    events->Array.reduce(Behavior.initialState, Behavior.evolve)

  let errors = ref([])

  let exec = (history, command): array<Spec.event> => {
    errors := []
    let state = currentState(history)
    switch Behavior.decide(state, command) {
    | Ok(events) => events
    | Error(error) =>
      errors := [error]
      []
    }
  }

  let givenEvents = events => events
  let whenCmd = (history, cmd) => history->exec(cmd)

  let encEvent = (e: Spec.event) => e->Message.encode(Spec.eventSchema)
  let encEvents = evs => evs->Array.map(encEvent)
  let encError = (err: Spec.error) => err->Message.encode(Spec.errorSchema)

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
    if errors.contents->Array.length > 0 {
      unexpectedError(events)
    } else if events == expectedEvents {
      Outcome.pass
    } else {
      Outcome.fail(
        EventsMismatch({expected: expectedEvents->encEvents, actual: events->encEvents}),
      )
    }

  let thenCompareEvents = (events, expectedEvents, cmp) =>
    if errors.contents->Array.length > 0 {
      unexpectedError(events)
    } else if (
      events->Array.length == expectedEvents->Array.length &&
        Array.zip(events, expectedEvents)->Array.every(((e1, e2)) => cmp(e1, e2))
    ) {
      Outcome.pass
    } else {
      Outcome.fail(
        EventsMismatch({expected: expectedEvents->encEvents, actual: events->encEvents}),
      )
    }

  let thenEvent = (events, expectedEvent) => thenEvents(events, [expectedEvent])

  let thenCompareEvent = (events, expectedEvent, cmp) =>
    thenCompareEvents(events, [expectedEvent], cmp)

  let thenNoEvent = events =>
    if errors.contents->Array.length > 0 {
      unexpectedError(events)
    } else if events->Array.length == 0 {
      Outcome.pass
    } else {
      Outcome.fail(NoEventExpected({actual: events->encEvents}))
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

  let thenError = (events, expectedError) => matchesError(events, [], expectedError)

  let thenEventWithError = (events, expectedEvent, expectedError) =>
    matchesError(events, [expectedEvent], expectedError)

  let thenEventsWithError = (events, expectedEvents, expectedError) =>
    matchesError(events, expectedEvents, expectedError)
}
