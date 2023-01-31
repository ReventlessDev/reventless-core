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

let logAction = str => Js.log2("Projection.handleAction:", str);

let handleAction = (action, {load, save, saveBatch, delete}, subIdConfig) =>
  switch (action) {
  | Ignore =>
    logAction("Ignore");
    [|Ok()->Js.Promise.resolve|];

  | Create(id, state) =>
    logAction({j|Create($id, $state)|j});
    [|save(. id, state, Init, None)|];
  | CreateMultiState(id, states) =>
    logAction({j|CreateMultiState($id, $states)|j});
    switch (states) {
    | [||] => [|Ok()->Js.Promise.resolve|]
    | [|state|] => [|save(. id, state, Init, None)|]
    | states =>
      let batch = states->Belt.Array.map(state => (id, state, None));
      [|saveBatch(. batch)|];
    };
  | CreateMany(states) =>
    let batch = states->Belt.Array.map(((id, state)) => (id, state, None));
    let statesStr =
      batch->Belt.Array.map(((id, state, _)) => {j|($id,$state)|j});
    logAction({j|CreateMany($statesStr)|j});
    [|saveBatch(. batch)|]; // TODO: think about using single saves with saveMode Init

  | Set(id, state) =>
    logAction({j|Set($id, $state)|j});
    [|save(. id, state, Any, None)|];
  | SetMany(ids, set) =>
    let batch = ids->Belt.Array.map(id => (id, set(id), None));
    let statesStr =
      batch->Belt.Array.map(((id, state, _)) => {j|($id,$state)|j});
    logAction({j|SetMany($statesStr)|j});
    [|saveBatch(. batch)|];

  | Update(id, update) => [|
      load(. id)
      ->Js.Promise.then_(
          fun
          | Ok(states) =>
            switch (states) {
            | [] =>
              logAction({j|Update Error: No oldState for $id)|j});
              Error(StaleState)->Js.Promise.resolve;
            | [oldState] =>
              let newState = oldState->update;
              logAction({j|Update($id, $oldState => $newState)|j});
              save(. id, newState, Overwrite, None);
            | _ =>
              logAction({j|Update Error: Multiple oldStates for $id)|j});
              Error(StaleState)->Js.Promise.resolve;
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
            | [] =>
              logAction({j|UpdateWithDefault($id, default: $default)|j});
              save(. id, default, Init, None);
            | [oldState] =>
              let newState = oldState->update;
              logAction({j|UpdateWithDefault($id, $oldState => $newState)|j});
              save(. id, newState, Overwrite, None);
            | _ =>
              logAction(
                {j|UpdateWithDefault Error: Multiple oldStates for $id)|j},
              );
              Error(StaleState)->Js.Promise.resolve;
            }
          | Error(err) => {
              logAction(
                {j|UpdateWithDefault Error: Couldn't load oldState(s) for $id: $err)|j},
              );
              Error(err)->Js.Promise.resolve;
            },
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
              let batch =
                newStates->Belt.Array.map(state => (id, state, None));
              let newSubIds =
                newStates
                ->Belt.Array.map(state => state->getSubId)
                ->Set.fromArray;
              let subIdsToDelete = oldSubIds->Set.diff(newSubIds);

              let statesStr =
                batch->Belt.Array.map(((id, state, _)) =>
                  {j|($id,$state)|j}
                );
              logAction({j|UpdateMultiState($statesStr)|j});

              subIdsToDelete
              ->Set.toArray
              ->Belt.Array.map(subId => {
                  logAction({j|UpdateMultiState: Delete($id, $subId)|j});
                  delete(. id, Some((subIdField, subId)));
                })
              ->Belt.Array.concat([|saveBatch(. batch)|])
              ->Js.Promise.all
              ->Js.Promise.then_(_ => Ok()->Js.Promise.resolve, _);
            | (Error(err), Some(_)) =>
              logAction(
                {j|UpdateMultiState Error: Couldn't load oldStates for $id: $err)|j},
              );
              Error(err)->Js.Promise.resolve;
            | (_, None) =>
              logAction("UpdateMultiState Error: Missing SubIdConfig !");
              Error(MissingSubIdConfig)->Js.Promise.resolve;
            },
          _,
        ),
    |]
  | Delete(id) =>
    logAction({j|Delete($id)|j});
    [|delete(. id, None)|];
  | DeleteMany(ids) =>
    logAction({j|Create($ids)|j});
    ids->Belt.Array.map(id => delete(. id, None));

  // TODO: add missing actions
  | _ =>
    logAction("Error: Action not yet supported !");
    [|Ok()->Js.Promise.resolve|];
  };

let handleActions = (actions, primitives, subIdConfig) => {
  actions
  ->Belt.Array.map(action => action->handleAction(primitives, subIdConfig))
  ->Belt.Array.concatMany;
};
