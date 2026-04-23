open ReventlessCore

// Minimal inline spec — parallels the pattern in Behavior_GWT so that sury-ppx
// processes the @schema attributes in this compilation unit. Matches the
// relevant subset of `Reventless.StateChangeSlice.Spec`.
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
}

module Make = (Spec: SliceSpec): (T with module Spec = Spec) => {
  module Spec = Spec

  S.enableJson()

  let describe = JestBind.describe
  let test = (name, body) => JestBind.test(~slice=Spec.name, name, body)

  let currentState = consumed =>
    consumed->Array.reduce(Spec.initialState, Spec.evolve)

  let errors = ref([])

  let exec = (history, command): array<Spec.event> => {
    errors := []
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

  let thenEvent = (events, expectedEvent) => thenEvents(events, [expectedEvent])

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
