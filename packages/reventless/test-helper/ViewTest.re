module type T = {
  type event;
  type state;

  let givenEvents: list(event) => list(state);
  let whenEvent:
    (event, list(state)) => Jest.Expect.plainPartial(unit => list(state));
  let thenStates:
    (list(state), Jest.Expect.plainPartial(unit => list(state))) =>
    Jest.assertion;
  let thenState:
    (state, Jest.Expect.plainPartial(unit => list(state))) => Jest.assertion;
  let thenNoState:
    Jest.Expect.plainPartial(unit => list(state)) => Jest.assertion;
  let thenThrow:
    Jest.Expect.plainPartial(unit => list(state)) => Jest.assertion;
};

let unpack: Jest.Expect.plainPartial('a) => 'a =
  p => {
    switch (p) {
    | `Just(unpacked) => unpacked
    };
  };

module Make =
       (
         Service: Message.Service,
         View: View.T with type event := Service.event,
       )
       : (T with type event := Service.event and type state := View.state) => {
  open View;

  let applyAction =
    fun
    | Reventless.View.Create(state) => [state]
    | Update(newState) => [newState]
    | Delete(_) => []
    | Unchanged(state) => [state];

  let applyActions = actions =>
    actions |> List.map(applyAction) |> List.flatten;

  let update = (event, states) =>
    switch (states) {
    | [] => init(. event, TestFixtures.context)
    | [oldState] =>
      apply(. oldState, event, TestFixtures.context) |> applyActions
    | oldStates =>
      applyMulti(. oldStates, event, TestFixtures.context) |> applyActions
    };

  let givenEvents = events => {
    let rec append = (events, states) =>
      switch (events) {
      | [] => states
      | [hd, ...tl] => update(hd, states) |> append(tl)
      };
    append(events, []);
  };

  open Jest.Expect;
  let whenEvent = (event, state) => expect(() =>
                                       update(event, state)
                                     );

  let thenStates = (expectedStates, states) => {
    let states = states |> unpack;
    expect(states()) |> toEqual(expectedStates);
  };

  let thenState = (expectedState, statesFn) => {
    let statesFn = statesFn |> unpack;
    let states = statesFn();
    expect((states |> List.length, states->Belt.List.head))
    |> toEqual((1, Some(expectedState)));
  };

  let thenNoState = states => {
    let states = states |> unpack;
    expect(states()) |> toEqual([]);
  };

  let thenThrow = states => states |> toThrow;
};