open ReventlessSpec.Projection.Spec;
open ReventlessSpec.ReadModelSpec;
open Belt.Result;
open QueryDb;

module Set = Belt.Set.String;

type primitives('id, 'state) = {
  load: load('id, 'state),
  save: save('id, 'state),
  saveBatch: saveBatch('id, 'state),
  delete: delete('id),
};

let handleAction = (action, {load, save, saveBatch, delete}, subIdConfig) =>
  switch (action) {
  | Create(id, state) => [|save(. id, state, Init, None)|]
  | CreateMultiState(id, states) =>
    switch (states) {
    | [||] => [|Ok()->Js.Promise.resolve|]
    | [|state|] => [|save(. id, state, Init, None)|]
    | states =>
      let batch = states->Belt.Array.map(state => (id, state, None));
      [|saveBatch(. batch)|];
    }
  | CreateMany(states) =>
    let batch = states->Belt.Array.map(((id, state)) => (id, state, None));
    [|saveBatch(. batch)|]; // TODO: think about using single saves with saveMode Init

  | Set(id, state) => [|save(. id, state, Any, None)|]
  | SetMany(ids, set) =>
    let batch = ids->Belt.Array.map(id => (id, set(id), None));
    [|saveBatch(. batch)|];

  | Update(id, update) => [|
      load(. id)
      ->Js.Promise.then_(
          fun
          | Ok(states) =>
            switch (states) {
            | [] => Error(StaleState)->Js.Promise.resolve
            | [state] =>
              let newState = state->update;
              save(. id, newState, Overwrite, None);
            | _ => Error(StaleState)->Js.Promise.resolve
            }
          | Error(err) => Error(err)->Js.Promise.resolve,
          _,
        ),
    |]
  | UpdateWithDefault(id, default, update) => [|
      load(. id)
      ->Js.Promise.then_(
          fun
          | Ok(states) =>
            switch (states) {
            | [] => save(. id, default, Init, None)
            | [state] =>
              let newState = state->update;
              save(. id, newState, Overwrite, None);
            | _ => Error(StaleState)->Js.Promise.resolve
            }
          | Error(err) => Error(err)->Js.Promise.resolve,
          _,
        ),
    |]
  | UpdateMultiState(id, update) => [|
      load(. id)
      // TODO: error handling
      ->Js.Promise.then_(
          states =>
            switch (states, subIdConfig) {
            | (Ok(states), Some({subIdField, getSubId})) =>
              let oldStates = states->Belt.List.toArray;
              let oldSubIds =
                oldStates
                ->Belt.Array.map(state => state->getSubId)
                ->Set.fromArray;
              let newStates = oldStates->update;
              let newSubIds =
                newStates
                ->Belt.Array.map(state => state->getSubId)
                ->Set.fromArray;
              let subIdsToDelete = oldSubIds->Set.diff(newSubIds);
              let subIdsToAdd = newSubIds->Set.diff(oldSubIds);
              let statesToAdd =
                newStates->Belt.Array.keep(state =>
                  subIdsToAdd->Set.has(state->getSubId)
                );

              subIdsToDelete
              ->Set.toArray
              ->Belt.Array.map(subId =>
                  delete(. id, Some((subIdField, subId)))
                )
              ->Belt.Array.concat([|
                  saveBatch(.
                    statesToAdd->Belt.Array.map(state => (id, state, None)),
                  ),
                |])
              ->Js.Promise.all
              ->Js.Promise.then_(_ => Ok()->Js.Promise.resolve, _);
            | (Error(err), Some(_)) => Error(err)->Js.Promise.resolve
            | (_, None) => Error(MissingSubIdConfig)->Js.Promise.resolve
            },
          _,
        ),
    |]
  | Delete(id) => [|delete(. id, None)|]
  | DeleteMany(ids) => ids->Belt.Array.map(id => delete(. id, None))

  // TODO: add missing actions
  | _ =>
    Js.log("Action not yet supported !");
    [|Ok()->Js.Promise.resolve|];
  };

let handleActions = (actions, primitives, subIdConfig) => {
  actions
  ->Belt.Array.map(action => action->handleAction(primitives, subIdConfig))
  ->Belt.Array.concatMany;
};
