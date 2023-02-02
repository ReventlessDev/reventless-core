module type T = {
  module Spec: Behaviour.Spec;

  let givenEvents: list(Spec.event) => list(Spec.event);

  let whenCmd: (Spec.command, list(Spec.event)) => list(Spec.event);
  let whenCmdWithId:
    (string, Spec.command, list(Spec.event)) => list(Spec.event);

  let thenEvent: (Spec.event, list(Spec.event)) => Jest.assertion;
  let thenNoEvent: list(Spec.event) => Jest.assertion;
  let thenEventWithError:
    (Spec.event, Spec.error, list(Spec.event)) => Jest.assertion;
  let thenEvents: (list(Spec.event), list(Spec.event)) => Jest.assertion;
  let thenEventsWithError:
    (list(Spec.event), Spec.error, list(Spec.event)) => Jest.assertion;
  let thenError: (Spec.error, list(Spec.event)) => Jest.assertion;
};

module Make =
       (Spec: Behaviour.Spec, Behaviour: Behaviour.T with module Spec := Spec)
       : (T with module Spec = Spec) => {
  module Spec = Spec;

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

  let exec = (context, command, history): list(Spec.event) => {
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
  let whenCmd = cmd => exec(TestFixtures.context, cmd);
  let whenCmdWithId = (id, cmd) => exec({...TestFixtures.context, id}, cmd);

  open Jest.Expect;

  let thenEvents = (expectedEvents, events) =>
    expect(((errors^)->Belt.List.length, events))
    ->toEqual((0, expectedEvents));

  let thenEvent = (expectedEvent, events) =>
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

  let thenEventWithError = (expectedEvent, expectedError, events) =>
    expect((
      events->Belt.List.length,
      events->Belt.List.head,
      (errors^)->Belt.List.length,
      (errors^)->Belt.List.head,
    ))
    ->toEqual((1, Some(expectedEvent), 1, Some(expectedError)));

  let thenEventsWithError = (expectedEvents, expectedError, events) =>
    expect((events, (errors^)->Belt.List.length, (errors^)->Belt.List.head))
    ->toEqual((expectedEvents, 1, Some(expectedError)));

  let thenError = (expectedError, events) => {
    expect((events, (errors^)->Belt.List.length, (errors^)->Belt.List.head))
    ->toEqual(([], 1, Some(expectedError)));
  };
};
