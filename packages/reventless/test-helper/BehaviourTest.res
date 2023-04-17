module type T = {
  module Spec: Behaviour.Spec

  let describe: (string, unit => unit) => unit
  let test: (string, unit => Jest.assertion) => unit

  let givenEvents: list<Spec.event> => list<Spec.event>

  let whenCmd: (list<Spec.event>, Spec.command) => list<Spec.event>
  let whenCmdWithId: (list<Spec.event>, string, Spec.command) => list<Spec.event>

  let thenEvent: (list<Spec.event>, Spec.event) => Jest.assertion
  let thenCompareEvent: (
    list<Spec.event>,
    Spec.event,
    (Spec.event, Spec.event) => bool,
  ) => Jest.assertion
  let thenNoEvent: list<Spec.event> => Jest.assertion
  let thenEventWithError: (list<Spec.event>, Spec.event, Spec.error) => Jest.assertion
  let thenEvents: (list<Spec.event>, list<Spec.event>) => Jest.assertion
  let thenCompareEvents: (
    list<Spec.event>,
    list<Spec.event>,
    (Spec.event, Spec.event) => bool,
  ) => Jest.assertion
  let thenEventsWithError: (list<Spec.event>, list<Spec.event>, Spec.error) => Jest.assertion
  let thenError: (list<Spec.event>, Spec.error) => Jest.assertion
}

module Make = (Spec: Behaviour.Spec, Behaviour: Behaviour.T with module Spec := Spec): (
  T with module Spec = Spec
) => {
  module Spec = Spec

  let describe = Jest.describe
  let test = Jest.test

  let apply' = (state, event) => Behaviour.apply(. state, event)

  let currentState = events => {
    open Belt.List
    events->tailExn->reduce(Behaviour.init(. events->headExn), apply')
  }

  let errors = ref(list{})

  let errorHandler: Message.errorHandler<Spec.error, Spec.command, Spec.event> = (error, _, _) => {
    errors := Belt.List.concat(errors.contents, list{error})
    list{}
  }

  let exec = (history, context, command): list<Spec.event> => {
    errors := list{}
    switch history {
    | list{} => Behaviour.create(. command, context, errorHandler)
    | history =>
      try Behaviour.execute(.
        currentState(history),
        command,
        TestFixtures.context,
        errorHandler,
      ) catch {
      | Reventless.Message.InvalidEvent(_) => list{}
      }
    }
  }

  let givenEvents = events => events
  let whenCmd = (history, cmd) => history->exec(TestFixtures.context, cmd)
  let whenCmdWithId = (history, id, cmd) => history->exec({...TestFixtures.context, id}, cmd)

  open Jest.Expect

  let thenEvents = (events, expectedEvents) =>
    expect((errors.contents->Belt.List.length, events))->toEqual((0, expectedEvents))

  let compare = (cmp, e1, e2) => {
    let cmpResult = cmp(e1, e2)
    if !cmpResult {
      Js.log3("Events do not match:", e1, e2)
    }
    cmpResult
  }

  let thenCompareEvents = (events, expectedEvents, cmp) =>
    expect((
      errors.contents->Belt.List.length,
      events->Belt.List.length,
      Belt.List.zip(events, expectedEvents)
      ->Belt.List.map(((event, expectedEvent)) => cmp->compare(event, expectedEvent))
      ->Belt.List.every(result => result),
    ))->toEqual((0, expectedEvents->Belt.List.length, true))

  let listErrors = () =>
    "Errors occured: " ++
    errors.contents
    ->Belt.List.map(err =>
      /* NOTE: this process is very fragile!!
              it relies on decco decoding the error-varints to arrays of string
 */
      (err->Spec.error_encode->Js.Json.decodeArray->Belt.Option.getExn)[0]
      ->Js.Json.decodeString
      ->Belt.Option.getExn
    )
    ->Belt.List.reduce("", (a, b) => a ++ (b ++ " "))

  let thenEvent = (events, expectedEvent) =>
    if events->Belt.List.length > 0 {
      expect((
        errors.contents->Belt.List.length,
        events->Belt.List.length,
        events->Belt.List.head,
      ))->toEqual((0, 1, Some(expectedEvent)))
    } else if errors.contents->Belt.List.length > 0 {
      listErrors()->Jest.fail
    } else {
      Jest.fail("thenEvent: No event present to validate")
    }

  let thenCompareEvent = (events, expectedEvent, cmp) =>
    if events->Belt.List.length > 0 {
      let firstEvent = events->Belt.List.head->Belt.Option.getExn
      expect((
        errors.contents->Belt.List.length,
        events->Belt.List.length,
        cmp->compare(firstEvent, expectedEvent),
      ))->toEqual((0, 1, true))
    } else if errors.contents->Belt.List.length > 0 {
      listErrors()->Jest.fail
    } else {
      Jest.fail("thenEvent: No event present to validate")
    }

  let thenNoEvent = thenEvents(list{})

  let thenEventWithError = (events, expectedEvent, expectedError) =>
    expect((
      events->Belt.List.length,
      events->Belt.List.head,
      errors.contents->Belt.List.length,
      errors.contents->Belt.List.head,
    ))->toEqual((1, Some(expectedEvent), 1, Some(expectedError)))

  let thenEventsWithError = (events, expectedEvents, expectedError) =>
    expect((events, errors.contents->Belt.List.length, errors.contents->Belt.List.head))->toEqual((
      expectedEvents,
      1,
      Some(expectedError),
    ))

  let thenError = (events, expectedError) =>
    expect((events, errors.contents->Belt.List.length, errors.contents->Belt.List.head))->toEqual((
      list{},
      1,
      Some(expectedError),
    ))
}
