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
  deleteBatch: deleteBatch('id),
};

let logAction = str => Js.log2("Projection.handleAction:", str);

let handleAction =
    (action, {load, save, saveBatch, delete, deleteBatch}, subIdConfig) =>
  switch (action) {
  | Ignore =>
    logAction("Ignore");
    Ok()->Js.Promise.resolve;

  | Create(id, state) =>
    logAction({j|Create($id, $state)|j});
    save(. id, state, Init, None);
  | CreateMultiState(id, states) =>
    logAction({j|CreateMultiState($id, $states)|j});
    switch (states) {
    | [||] => Ok()->Js.Promise.resolve
    | [|state|] => save(. id, state, Init, None)
    | states =>
      let batch = states->Belt.Array.map(state => (id, state, None));
      saveBatch(. batch);
    };
  | CreateMany(states) =>
    let batch = states->Belt.Array.map(((id, state)) => (id, state, None));
    let statesStr =
      batch->Belt.Array.map(((id, state, _)) => {j|($id,$state)|j});
    logAction({j|CreateMany($statesStr)|j});
    saveBatch(. batch); // TODO: think about using single saves with saveMode Init

  | Set(id, state) =>
    logAction({j|Set($id, $state)|j});
    save(. id, state, Any, None);
  | SetMany(ids, set) =>
    let batch = ids->Belt.Array.map(id => (id, set(id), None));
    let statesStr =
      batch->Belt.Array.map(((id, state, _)) => {j|($id,$state)|j});
    logAction({j|SetMany($statesStr)|j});
    saveBatch(. batch);

  | Update(id, update) =>
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
      )
  | UpdateWithDefault(id, default, update) =>
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
      )
  | UpdateMultiState(id, update) =>
    load(. id)
    // TODO: error handling
    ->Js.Promise.then_(
        states =>
          switch (states, subIdConfig) {
          | (Ok(states), Some({subIdField, getSubId})) =>
            let beforeStates = states->Belt.List.toArray;
            let beforeCount = beforeStates->Belt.Array.length;
            let beforeSubIds =
              beforeStates
              ->Belt.Array.map(state => state->getSubId)
              ->Set.fromArray;

            let afterStates = beforeStates->update;
            let afterCount = afterStates->Belt.Array.length;
            let afterSubIds =
              afterStates
              ->Belt.Array.map(state => state->getSubId)
              ->Set.fromArray;

            let addedSubIds = afterSubIds->Set.diff(beforeSubIds);
            let addedStates =
              afterStates->Belt.Array.keep(state =>
                addedSubIds->Set.has(state->getSubId)
              );
            let addedCount = addedStates->Belt.Array.size;

            let changedStates =
              beforeStates->Belt.Array.keepMap(before => {
                let beforeSubId = before->getSubId;
                afterStates->Belt.Array.getBy(after =>
                  after->getSubId == beforeSubId && after != before
                );
              });
            let changedCount = changedStates->Belt.Array.size;

            let batchToSave =
              addedStates
              ->Belt.Array.concat(changedStates)
              ->Belt.Array.map(state => (id, state, None));
            let batchCount = batchToSave->Belt.Array.size;

            let deletedSubIds =
              beforeSubIds->Set.diff(afterSubIds)->Set.toArray;
            let batchToDelete =
              deletedSubIds->Belt.Array.map(subId =>
                (id, Some((subIdField, subId)))
              );
            let deletedCount = batchToDelete->Belt.Array.size;

            logAction(
              {j|UpdateMultiState($id): beforeStates:$beforeCount afterStates:$afterCount added:$addedCount changed:$changedCount deleted:$deletedCount|j},
            );
            [|
              deletedCount > 0
                ? deleteBatch(. batchToDelete) : Ok()->Js.Promise.resolve,
              batchCount > 0
                ? saveBatch(. batchToSave) : Ok()->Js.Promise.resolve,
            |]
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
      )
  | Delete(id) =>
    logAction({j|Delete($id)|j});
    delete(. id, None);
  | DeleteMany(ids) =>
    logAction({j|DeleteMany($ids)|j});
    deleteBatch(. ids->Belt.Array.map(id => (id, None)));

  // TODO: add missing actions
  | _ =>
    logAction("Error: Action not yet supported !");
    Ok()->Js.Promise.resolve;
  };

let actionsWithId = action =>
  switch (action) {
  | Ignore => [||]
  | Create(id, _) => [|(id, action)|]
  | CreateMultiState(id, _) => [|(id, action)|]
  | CreateMany(states) =>
    states->Belt.Array.map(((id, state)) => (id, Create(id, state)))
  | Set(id, _) => [|(id, action)|]
  | SetMany(ids, set) => ids->Belt.Array.map(id => (id, Set(id, id->set)))
  | Update(id, _) => [|(id, action)|]
  | UpdateWithDefault(id, _, _) => [|(id, action)|]
  | UpdateMultiState(id, _) => [|(id, action)|]
  | Delete(id) => [|(id, action)|]
  | DeleteMany(ids) => ids->Belt.Array.map(id => (id, Delete(id)))

  // TODO: add missing actions
  | _ =>
    logAction("Error: Action not yet supported !");
    [||];
  };

let groupActionsById = actions => {
  let allActionsWithId =
    actions
    ->Belt.Array.map(action => action->actionsWithId)
    ->Belt.Array.concatMany;
  let ids = allActionsWithId->Belt.Array.map(((id, _)) => id);
  ids
  ->Belt.Set.String.fromArray
  ->Belt.Set.String.toArray
  ->Belt.Array.map(id =>
      (
        id,
        allActionsWithId->Belt.Array.keepMap(((actionId, action)) =>
          actionId == id ? Some(action) : None
        ),
      )
    );
};

let handleActions = (actions, primitives, subIdConfig) => {
  let handleActionsForId = (actions, id) => {
    let actionCount = actions->Belt.Array.size;
    if (actionCount > 1) {
      Js.log(
        {j|Projection.handleActions: handling $actionCount actions for id=$id|j},
      );
    };
    actions->Belt.Array.reduce(Ok()->Js.Promise.resolve, (p, action) =>
      Js.Promise.then_(_ => action->handleAction(primitives, subIdConfig), p)
    );
  };

  actions
  ->groupActionsById
  ->Belt.Array.map(((id, actions)) => actions->handleActionsForId(id));
};
