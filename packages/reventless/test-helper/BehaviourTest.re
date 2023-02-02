module type T = {
  module Spec: Behaviour.Spec;

  let describe: (string, unit => unit) => unit;
  let test: (string, unit => Jest.assertion) => unit;

  let givenEvents: list(Spec.event) => list(Spec.event);

  let whenCmd: (list(Spec.event), Spec.command) => list(Spec.event);
  let whenCmdWithId:
    (list(Spec.event), string, Spec.command) => list(Spec.event);

  let thenEvent: (list(Spec.event), Spec.event) => Jest.assertion;
  let thenNoEvent: list(Spec.event) => Jest.assertion;
  let thenEventWithError:
    (list(Spec.event), Spec.event, Spec.error) => Jest.assertion;
  let thenEvents: (list(Spec.event), list(Spec.event)) => Jest.assertion;
  let thenEventsWithError:
    (list(Spec.event), list(Spec.event), Spec.error) => Jest.assertion;
  let thenError: (list(Spec.event), Spec.error) => Jest.assertion;
};

module Make =
       (Spec: Behaviour.Spec, Behaviour: Behaviour.T with module Spec := Spec)
       : (T with module Spec = Spec) => {
  module Spec = Spec;

  let describe = Jest.describe;
  let test = Jest.test;

  let apply' = (state, event) => Behaviour.apply(. state, event);

  let currentState = events =>
    Belt.List.(
      events->tailExn->reduce(Behaviour.init(. events->headExn), apply')
    );

  let errors = ref([]);

  let errorHandler: Message.errorHandler(Spec.error, Spec.command, Spec.event) =
    (error, _, _) => {
      errors := errors^ @ [error];
      [];
    };

  let exec = (history, context, command): list(Spec.event) => {
    errors := [];
    switch (history) {
    | [] => Behaviour.create(. command, context, errorHandler)
    | history =>
      try(
        Behaviour.execute(.
          currentState(history),
          command,
          TestFixtures.context,
          errorHandler,
        )
      ) {
      | Reventless.Message.InvalidEvent(_) => []
      }
    };
  };

  let givenEvents = events => events;
  let whenCmd = (history, cmd) => history->exec(TestFixtures.context, cmd);
  let whenCmdWithId = (history, id, cmd) =>
    history->exec({...TestFixtures.context, id}, cmd);

  open Jest.Expect;

  let thenEvents = (events, expectedEvents) =>
    expect(((errors^)->Belt.List.length, events))
    ->toEqual((0, expectedEvents));

  let thenEvent = (events, expectedEvent) =>
    if (events->Belt.List.length > 0) {
      expect((
        (errors^)->Belt.List.length,
        events->Belt.List.length,
        events->Belt.List.head,
      ))
      ->toEqual((0, 1, Some(expectedEvent)));
    } else if ((errors^)->Belt.List.length > 0) {
      let errorMessages =
        (errors^)
        ->Belt.List.map(err
            /* NOTE: this process is very fragile!!
               it relies on decco decoding the error-varints to arrays of string
               */
            =>
              err->Spec.error_encode->Js.Json.decodeArray->Belt.Option.getExn[0]
              ->Js.Json.decodeString
              ->Belt.Option.getExn
            )
        ->Belt.List.reduce("", (a, b) => a ++ b ++ " ");
      Jest.fail("Errors occured: " ++ errorMessages);
    } else {
      Jest.fail("thenEvent: No event present to validate");
    };

  let thenNoEvent = thenEvents([]);

  let thenEventWithError = (events, expectedEvent, expectedError) =>
    expect((
      events->Belt.List.length,
      events->Belt.List.head,
      (errors^)->Belt.List.length,
      (errors^)->Belt.List.head,
    ))
    ->toEqual((1, Some(expectedEvent), 1, Some(expectedError)));

  let thenEventsWithError = (events, expectedEvents, expectedError) =>
    expect((events, (errors^)->Belt.List.length, (errors^)->Belt.List.head))
    ->toEqual((expectedEvents, 1, Some(expectedError)));

  let thenError = (events, expectedError) => {
    expect((events, (errors^)->Belt.List.length, (errors^)->Belt.List.head))
    ->toEqual(([], 1, Some(expectedError)));
  };
};
