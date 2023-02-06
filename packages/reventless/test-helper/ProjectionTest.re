module type T = {
  module Source: ReventlessSpec.Projection.Spec.Source;
  module Target: ReventlessSpec.Projection.Spec.Target;

  let describe: (string, unit => unit) => unit;
  let describeWithId: (string, string, unit => unit) => unit;
  let test:
    (string, ~timeout: int=?, unit => Js.Promise.t(Jest.assertion)) => unit;

  type store = Js.Dict.t(list(Target.state));

  let givenEvents: list(Source.event) => Js.Promise.t(store);
  let givenEventsWithTime:
    list((string, Source.event)) => Js.Promise.t(store);
  let whenEvent:
    (Js.Promise.t(store), Source.event) =>
    Jest.Expect.plainPartial(unit => Js.Promise.t(store));
  let whenEventWithTime:
    (Js.Promise.t(store), string, Source.event) =>
    Jest.Expect.plainPartial(unit => Js.Promise.t(store));
  let thenStates:
    (
      Jest.Expect.plainPartial(unit => Js.Promise.t(store)),
      list(Target.state)
    ) =>
    Js.Promise.t(Jest.assertion);
  let thenAllStates:
    (Jest.Expect.plainPartial(unit => Js.Promise.t(store)), store) =>
    Js.Promise.t(Jest.assertion);
  let thenState:
    (Jest.Expect.plainPartial(unit => Js.Promise.t(store)), Target.state) =>
    Js.Promise.t(Jest.assertion);
  let thenStateWithId:
    (
      Jest.Expect.plainPartial(unit => Js.Promise.t(store)),
      string,
      Target.state
    ) =>
    Js.Promise.t(Jest.assertion);
  let thenNoState:
    Jest.Expect.plainPartial(unit => Js.Promise.t(store)) =>
    Js.Promise.t(Jest.assertion);
  let thenThrow:
    Jest.Expect.plainPartial(unit => Js.Promise.t(store)) =>
    Js.Promise.t(Jest.assertion);
  let thenFail:
    Jest.Expect.plainPartial(unit => Js.Promise.t(store)) =>
    Js.Promise.t(Jest.assertion);
};

let unpack: Jest.Expect.plainPartial('a) => 'a =
  p => {
    switch (p) {
    | `Just(unpacked) => unpacked
    };
  };

let handleAction = Projection.handleAction; // create alias to avoid shadowing of same named modules

module Make =
       (Projection: ReventlessSpec.Projection.Mapping)

         : (
           T with
             module Source = Projection.Source and
             module Target = Projection.Target
       ) => {
  module Source = Projection.Source;
  module Target = Projection.Target;

  let testId = ref(TestFixtures.id);
  let meta = ref(TestFixtures.meta);

  let describe = Jest.describe;
  let describeWithId = (description, id, fn) => {
    testId := id;
    Jest.describe(description, fn);
  };
  let test = Jest.testPromise;

  type store = Js.Dict.t(list(Target.state));

  let getSubId = state =>
    Target.subIdConfig->Belt.Option.map(({getSubId}) => state->getSubId);
  let hasSubId = (subId, state) =>
    state->getSubId->Belt.Option.getExn == subId;
  let states = (store, id) =>
    store->Js.Dict.get(id)->Belt.Option.getWithDefault([]);
  let setStates = (store, id, states) => store->Js.Dict.set(id, states);
  let updateState = (store, id, subId, newState) =>
    store
    ->states(id)
    ->Belt.List.map(state => hasSubId(subId, state) ? newState : state);
  let addState = (store, id, state) => {
    let (updatedStates, newStates) =
      switch (state->getSubId) {
      | Some(subId) =>
        store->states(id)->Belt.List.some(hasSubId(subId))
          ? (store->updateState(id, subId, state), [])
          : (store->states(id), [state])
      | None => (store->states(id), [state])
      };
    store->Js.Dict.set(id, updatedStates @ newStates);
  };
  let deleteStates = (store, id) => store->Js.Dict.set(id, []);
  let deleteSubStates = (store, id, subId, getSubId) =>
    store->Js.Dict.set(
      id,
      store
      ->Js.Dict.get(id)
      ->Belt.Option.map(states =>
          states->Belt.List.keep(state => state->getSubId != subId)
        )
      ->Belt.Option.getWithDefault([]),
    );

  open Belt.Result;
  open QueryDb;
  let load = store => (. id) => store->states(id)->Ok->Js.Promise.resolve;
  let save = store =>
    (. id, state, saveMode, _ttl) =>
      switch (store->states(id), saveMode) {
      | (_, Any)
      | ([], Init)
      | ([_], Overwrite) =>
        store->setStates(id, [state]);
        Ok()->Js.Promise.resolve;
      | _ => Error(StaleState)->Js.Promise.resolve
      };
  let saveBatch = store =>
    (. batch) => {
      batch->Belt.Array.forEach(((id, state, _ttl)) =>
        store->addState(id, state)
      );
      Ok()->Js.Promise.resolve;
    };
  let delete = store =>
    (. id, subId) =>
      switch (subId, Target.subIdConfig) {
      | (None, _) =>
        store->deleteStates(id);
        Ok()->Js.Promise.resolve;
      | (Some((_, subId)), Some({ReventlessSpec.ReadModelSpec.getSubId})) =>
        store->deleteSubStates(id, subId, getSubId);
        Ok()->Js.Promise.resolve;
      | _ => Ok()->Js.Promise.resolve
      };

  let handleAction = (action, primitives) =>
    action
    ->handleAction(primitives, Target.subIdConfig)
    ->Js.Promise.all
    ->Js.Promise.then_(
        results => {
          results->Belt.Array.forEach(result =>
            switch (result) {
            | Error(err) =>
              Js.Exn.raiseError(
                err->QueryDb.storageError_encode->Js.Json.stringify,
              )
            | _ => ()
            }
          );
          Js.Promise.resolve();
        },
        _,
      );

  let update = (store, id, meta, event) => {
    let logStore = text =>
      Js.log4(
        text,
        event->Source.event_encode,
        "\nstore:",
        store
        ->Js.Dict.get(id)
        ->Belt.Option.getWithDefault([])
        ->Belt.List.map(Target.state_encode),
      );
    let resolveStore = () => {
      // logStore("update after event:");
      store->Js.Promise.resolve;
    };

    {id, meta, event}
    ->Projection.map
    ->handleAction({
        load: load(store),
        save: save(store),
        saveBatch: saveBatch(store),
        delete: delete(store),
      })
    ->Js.Promise.then_(_ => resolveStore(), _);
  };

  let givenEvents = events => {
    events
    ->Belt.List.reduce(Js.Dict.empty()->Js.Promise.resolve, (p, event) =>
        p->Js.Promise.then_(store => store->update(testId^, meta^, event), _)
      )
    ->Js.Promise.then_(store => store->Js.Promise.resolve, _);
  };
  let givenEventsWithTime = events => {
    events
    ->Belt.List.reduce(
        Js.Dict.empty()->Js.Promise.resolve, (p, (time, event)) =>
        p->Js.Promise.then_(
             store => store->update(testId^, {...meta^, time}, event),
             _,
           )
      )
    ->Js.Promise.then_(store => store->Js.Promise.resolve, _);
  };

  open Jest.Expect;
  let whenEvent = (p, event) =>
    expect(() =>
      p->Js.Promise.then_(store => store->update(testId^, meta^, event), _)
    );
  let whenEventWithTime = (p, time, event) =>
    expect(() =>
      p->Js.Promise.then_(
           store => store->update(testId^, {...meta^, time}, event),
           _,
         )
    );

  let thenStates = (p, expectedStates) => {
    p
    ->unpack()
    ->Js.Promise.then_(
        store =>
          (
            expect((
              store->Js.Dict.keys->Belt.Array.length,
              store->Js.Dict.keys->Belt.Array.get(0),
              store
              ->Js.Dict.values
              ->Belt.Array.get(0)
              ->Belt.Option.getWithDefault([]),
            ))
            |> toEqual((1, Some(testId^), expectedStates))
          )
          ->Js.Promise.resolve,
        _,
      );
  };
  let thenAllStates = (p, expectedStore: store) => {
    p
    ->unpack()
    ->Js.Promise.then_(
        store =>
          (expect(store) |> toEqual(expectedStore))->Js.Promise.resolve,
        _,
      );
  };
  let thenState = (p, expectedState) => {
    p
    ->unpack()
    ->Js.Promise.then_(
        store =>
          (
            expect((
              store->Js.Dict.keys->Belt.Array.length,
              store->Js.Dict.keys->Belt.Array.get(0),
              store
              ->Js.Dict.values
              ->Belt.Array.get(0)
              ->Belt.Option.getWithDefault([])
              ->Belt.List.length,
              store->Js.Dict.values[0]->Belt.List.head,
            ))
            |> toEqual((1, Some(testId^), 1, Some(expectedState)))
          )
          ->Js.Promise.resolve,
        _,
      );
  };
  let thenStateWithId = (p, id, expectedState) => {
    p
    ->unpack()
    ->Js.Promise.then_(
        store =>
          (
            expect((
              store->Js.Dict.keys->Belt.Array.length,
              store->Js.Dict.keys->Belt.Array.get(0),
              store
              ->Js.Dict.values
              ->Belt.Array.get(0)
              ->Belt.Option.getWithDefault([])
              ->Belt.List.length,
              store->Js.Dict.values[0]->Belt.List.head,
            ))
            |> toEqual((1, Some(id), 1, Some(expectedState)))
          )
          ->Js.Promise.resolve,
        _,
      );
  };
  let thenNoState = p => {
    p
    ->unpack()
    ->Js.Promise.then_(
        store =>
          (expect(store) |> toEqual(Js.Dict.empty()))->Js.Promise.resolve,
        _,
      );
  };
  let thenThrow = p =>
    p->unpack()->Js.Promise.then_(_ => p->toThrow->Js.Promise.resolve, _);

  let thenFail = p =>
    p
    ->unpack()
    ->Js.Promise.then_(
        _ => Jest.fail("Expected Failure")->Js.Promise.resolve,
        _,
      )
    ->Js.Promise.catch(_ => Jest.pass->Js.Promise.resolve, _);
};
