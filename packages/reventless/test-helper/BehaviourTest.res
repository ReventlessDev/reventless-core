module type T = {
  module Spec: Behaviour.Spec

  let describe: (string, unit => unit) => unit
  let test: (string, unit => Jest.assertion) => unit

  let givenEvents: array<Spec.event> => array<Spec.event>

  let whenCmd: (array<Spec.event>, Spec.command) => array<Spec.event>
  let whenCmdWithId: (array<Spec.event>, string, Spec.command) => array<Spec.event>

  let thenEvent: (array<Spec.event>, Spec.event) => Jest.assertion
  let thenCompareEvent: (
    array<Spec.event>,
    Spec.event,
    (Spec.event, Spec.event) => bool,
  ) => Jest.assertion
  let thenNoEvent: array<Spec.event> => Jest.assertion
  let thenEventWithError: (array<Spec.event>, Spec.event, Spec.error) => Jest.assertion
  let thenEvents: (array<Spec.event>, array<Spec.event>) => Jest.assertion
  let thenCompareEvents: (
    array<Spec.event>,
    array<Spec.event>,
    (Spec.event, Spec.event) => bool,
  ) => Jest.assertion
  let thenEventsWithError: (array<Spec.event>, array<Spec.event>, Spec.error) => Jest.assertion
  let thenError: (array<Spec.event>, Spec.error) => Jest.assertion
}

module Make = (Spec: Behaviour.Spec, Behaviour: Behaviour.T with module Spec := Spec): (
  T with module Spec = Spec
) => {
  module Spec = Spec

  let describe = Jest.describe
  let test = Jest.test

  let apply' = (state, event) => Behaviour.apply(state, event)

  let currentState = events =>
    events
    ->Array.sliceToEnd(~start=1)
    ->Array.reduce(Behaviour.init(events->Array.getUnsafe(0)), apply')

  let errors = ref([])

  let errorHandler: Message.errorHandler<Spec.error, Spec.command, Spec.event> = (error, _, _) => {
    errors := Array.concat(errors.contents, [error])
    []
  }

  let exec = (history, context, command): array<Spec.event> => {
    errors := []
    switch history {
    | [] => Behaviour.create(command, context, errorHandler)
    | history =>
      try Behaviour.execute(
        currentState(history),
        command,
        TestFixtures.context,
        errorHandler,
      ) catch {
      | Reventless.Message.InvalidEvent(_) => []
      }
    }
  }

  let givenEvents = events => events
  let whenCmd = (history, cmd) => history->exec(TestFixtures.context, cmd)
  let whenCmdWithId = (history, id, cmd) => history->exec({...TestFixtures.context, id}, cmd)

  open Jest.Expect

  let thenEvents = (events, expectedEvents) =>
    expect((errors.contents->Array.length, events))->toEqual((0, expectedEvents))

  let compare = (cmp, e1, e2) => {
    let cmpResult = cmp(e1, e2)
    if !cmpResult {
      Js.log3("Events do not match:", e1, e2)
    }
    cmpResult
  }

  let thenCompareEvents = (events, expectedEvents, cmp) =>
    expect((
      errors.contents->Array.length,
      events->Array.length,
      Belt.Array.zip(events, expectedEvents)
      ->Array.map(((event, expectedEvent)) => cmp->compare(event, expectedEvent))
      ->Array.every(result => result),
    ))->toEqual((0, expectedEvents->Array.length, true))

  let listErrors = () =>
    "Errors occured: " ++
    errors.contents
    ->Array.map(err =>
      /* NOTE: this process is very fragile!!
              it relies on decco decoding the error-varints to arrays of string
 */
      err
      ->Message.encode(Spec.errorSchema)
      ->Js.Json.decodeArray
      ->Option.getExn
      ->Array.getUnsafe(0)
      ->Js.Json.decodeString
      ->Option.getExn
    )
    ->Array.reduce("", (a, b) => a ++ (b ++ " "))

  let thenEvent = (events, expectedEvent) =>
    if events->Array.length > 0 {
      expect((errors.contents->Array.length, events->Array.length, events->Array.get(0)))->toEqual((
        0,
        1,
        Some(expectedEvent),
      ))
    } else if errors.contents->Array.length > 0 {
      listErrors()->Jest.fail
    } else {
      Jest.fail("thenEvent: No event present to validate")
    }

  let thenCompareEvent = (events, expectedEvent, cmp) =>
    if events->Array.length > 0 {
      let firstEvent = events->Array.get(0)->Option.getExn
      expect((
        errors.contents->Array.length,
        events->Array.length,
        cmp->compare(firstEvent, expectedEvent),
      ))->toEqual((0, 1, true))
    } else if errors.contents->Array.length > 0 {
      listErrors()->Jest.fail
    } else {
      Jest.fail("thenEvent: No event present to validate")
    }

  let thenNoEvent = events => thenEvents(events, [])

  let thenEventWithError = (events, expectedEvent, expectedError) =>
    expect((
      events->Array.length,
      events->Array.get(0),
      errors.contents->Array.length,
      errors.contents->Array.get(0),
    ))->toEqual((1, Some(expectedEvent), 1, Some(expectedError)))

  let thenEventsWithError = (events, expectedEvents, expectedError) =>
    expect((events, errors.contents->Array.length, errors.contents->Array.get(0)))->toEqual((
      expectedEvents,
      1,
      Some(expectedError),
    ))

  let thenError = (events, expectedError) =>
    expect((events, errors.contents->Array.length, errors.contents->Array.get(0)))->toEqual((
      [],
      1,
      Some(expectedError),
    ))
}
