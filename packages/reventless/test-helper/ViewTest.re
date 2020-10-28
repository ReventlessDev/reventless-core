module type T = {
  module Spec: View.Spec;

  type state;

  let givenEvents: list(Spec.event) => list(state);
  let whenEvent:
    (Spec.event, list(state)) =>
    Jest.Expect.plainPartial(unit => list(state));
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
       (Spec: View.Spec, View: View.T with module Spec := Spec)
       : (T with module Spec = Spec and type state := View.state) => {
  module Spec = Spec;

  let transformState = (oldState, action) =>
    switch (action) {
    | Reventless.View.Create(_)
    | Unchanged(_) => [oldState]
    | Update(newState) => [newState]
    | Delete(_) => []
    };

  let createState = action =>
    switch (action) {
    | Reventless.View.Create(newState) => [newState]
    | _ => []
    };

  let applyActions = (actions, oldStates) =>
    oldStates
    ->Belt.List.zip(actions)
    ->Belt.List.map(((oldState, action)) =>
        oldState->transformState(action)
      )
    ->Belt.List.concat(actions->Belt.List.map(createState))
    ->Belt.List.flatten;

  let update = (event, states) =>
    switch (states) {
    | [] => View.init(. event, TestFixtures.context)
    | [oldState] =>
      View.apply(. oldState, event, TestFixtures.context)
      ->applyActions([oldState])
    | oldStates =>
      View.applyMulti(. oldStates, event, TestFixtures.context)
      ->applyActions(oldStates)
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
  let whenEvent = (event, states) => expect(() =>
                                        update(event, states)
                                      );

  let thenStates = (expectedStates, states) => {
    let states = states->unpack;
    expect(states()) |> toEqual(expectedStates);
  };

  let thenState = (expectedState, statesFn) => {
    let statesFn = statesFn->unpack;
    let states = statesFn();
    expect((states->Belt.List.length, states->Belt.List.head))
    |> toEqual((1, Some(expectedState)));
  };

  let thenNoState = states => {
    let states = states->unpack;
    expect(states()) |> toEqual([]);
  };

  let thenThrow = states => states->toThrow;
};
