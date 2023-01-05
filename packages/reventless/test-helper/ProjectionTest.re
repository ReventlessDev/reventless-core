module type T = {
  module Source: ReventlessSpec.Projection.Spec.Source;
  module Target: ReventlessSpec.Projection.Spec.Target;

  let describe: (string, unit => unit) => unit;
  let test:
    (string, ~timeout: int=?, unit => Js.Promise.t(Jest.assertion)) => unit;

  type store = Js.Dict.t(list(Target.state));

  let givenEvents: list(Source.event) => Js.Promise.t(store);
  let whenEvent:
    (Js.Promise.t(store), Source.event) =>
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
};

let unpack: Jest.Expect.plainPartial('a) => 'a =
  p => {
    switch (p) {
    | `Just(unpacked) => unpacked
    };
  };

let handleActions = Projection.handleActions; // create alias to avoid shadowing of same named modules

module Make =
       (
         Target: ReventlessSpec.Projection.Spec.Target,
         Projection:
           ReventlessSpec.Projection.Mapping with module Target := Target,
       )
       : (T with module Source = Projection.Source and module Target = Target) => {
  module Source = Projection.Source;
  module Target = Target;

  let describe = Jest.describe;
  let test = Jest.testPromise;

  type store = Js.Dict.t(list(Target.state));

  let states = (store, id) =>
    store->Js.Dict.get(id)->Belt.Option.getWithDefault([]);
  let setStates = (store, id, states) => store->Js.Dict.set(id, states);
  let addState = (store, id, state) =>
    store->Js.Dict.set(
      id,
      store->Js.Dict.get(id)->Belt.Option.getWithDefault([]) @ [state],
    );
  let deleteStates = (store, id) => store->Js.Dict.set(id, []);

  open Belt.Result;
  open ReventlessSpec.QueryDb;
  let load: store => ReventlessSpec.QueryDb.load(string, Target.state) =
    store => (. id) => store->states(id)->Ok->Js.Promise.resolve;
  let save: store => ReventlessSpec.QueryDb.save(string, Target.state) =
    store =>
      (. id, state, saveMode, _ttl) =>
        switch (store->states(id), saveMode) {
        | (_, Any)
        | ([], Init)
        | ([_], Overwrite) =>
          store->setStates(id, [state]);
          Ok()->Js.Promise.resolve;
        | _ => Error(StaleState)->Js.Promise.resolve
        };
  let saveBatch:
    store => ReventlessSpec.QueryDb.saveBatch(string, Target.state) =
    store =>
      (. batch) => {
        batch->Belt.Array.forEach(((id, state, _ttl)) =>
          store->addState(id, state)
        );
        Ok()->Js.Promise.resolve;
      };
  let delete: store => ReventlessSpec.QueryDb.delete(string) =
    store =>
      (. id, _sort) => {
        store->deleteStates(id);
        Ok()->Js.Promise.resolve;
      };

  let handleActions = (actions, primitives) =>
    actions
    ->handleActions(primitives)
    ->Js.Promise.all
    ->Js.Promise.then_(_ => Js.Promise.resolve(), _); // TODO: error handling

  let update = (store, event) =>
    [|event->Projection.map(TestFixtures.context)|]
    ->handleActions({
        ReventlessSpec.ReadModel.load: load(store),
        save: save(store),
        saveBatch: saveBatch(store),
        delete: delete(store),
      })
    ->Js.Promise.then_(_ => store->Js.Promise.resolve, _);

  let givenEvents = events => {
    events
    ->Belt.List.reduce(Js.Dict.empty()->Js.Promise.resolve, (p, event) =>
        p->Js.Promise.then_(store => store->update(event), _)
      )
    ->Js.Promise.then_(store => store->Js.Promise.resolve, _);
  };

  open Jest.Expect;
  let whenEvent = (p, event) =>
    expect(() =>
      p->Js.Promise.then_(store => store->update(event), _)
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
            |> toEqual((1, Some(TestFixtures.context.id), expectedStates))
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
            |> toEqual((
                 1,
                 Some(TestFixtures.context.id),
                 1,
                 Some(expectedState),
               ))
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
};
