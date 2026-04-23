open ReventlessCore

// Minimal spec the DSL requires — command / event / error schemas only.
// Defined inline (rather than referencing ReventlessCore.Behavior.Spec) so
// sury-ppx processes the @schema attributes in this compilation unit,
// matching how consumers' aggregate specs are generated.
module type BehaviorSpec = {
  @schema
  type command
  @schema
  type event
  @schema
  type error
}

module type T = {
  module Spec: BehaviorSpec

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

module Make = (
  Spec: BehaviorSpec,
  Behavior: Behavior.T with module Spec := Spec,
): (T with module Spec = Spec) => {
  module Spec = Spec

  S.enableJson()

  let describe = JestBind.describe
  let test = JestBind.test

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

  // Report an unexpected decide() error as ErrorMismatch with expected=null.
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

  // thenCompareEvent(s) keep the custom equality semantics of the original
  // DSL (used to compare events with non-structural equality, e.g. when an
  // event carries a generated UUID). Success is reported even if the raw
  // structural equality would fail; the mismatch carries the encoded event
  // payloads so downstream tools can still render them.
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

  // Handles all `thenError*` variants — expects a specific error. Priority:
  // 1. error missing or wrong → ErrorMismatch
  // 2. events don't match expected → EventsMismatch
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
