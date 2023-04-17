open ReventlessSpec.Projection.Spec
open ReventlessSpec.ReadModelSpec
open Belt.Result
open QueryDb

module Set = Belt.Set.String

type primitives<'id, 'state> = {
  load: load<'id, 'state>,
  save: save<'id, 'state>,
  saveBatch: saveBatch<'id, 'state>,
  delete: delete<'id>,
  deleteBatch: deleteBatch<'id>,
}

let logAction = str => Js.log2("Projection.handleAction:", str)

let applyChanges = (
  action,
  id,
  beforeStates,
  afterStates,
  {saveBatch, deleteBatch},
  {subIdField, getSubId},
) => {
  let beforeCount = beforeStates->Belt.Array.length
  let beforeSubIds = beforeStates->Belt.Array.map(state => state->getSubId)->Set.fromArray

  let afterCount = afterStates->Belt.Array.length
  let afterSubIds = afterStates->Belt.Array.map(state => state->getSubId)->Set.fromArray

  let addedSubIds = afterSubIds->Set.diff(beforeSubIds)
  let addedStates = afterStates->Belt.Array.keep(state => addedSubIds->Set.has(state->getSubId))
  let addedCount = addedStates->Belt.Array.size

  let changedStates = beforeStates->Belt.Array.keepMap(before => {
    let beforeSubId = before->getSubId
    afterStates->Belt.Array.getBy(after => after->getSubId == beforeSubId && after != before)
  })
  let changedCount = changedStates->Belt.Array.size

  let batchToSave =
    addedStates->Belt.Array.concat(changedStates)->Belt.Array.map(state => (id, state, None))

  let deletedSubIds = beforeSubIds->Set.diff(afterSubIds)->Set.toArray
  let batchToDelete = deletedSubIds->Belt.Array.map(subId => (id, Some((subIdField, subId))))
  let deletedCount = batchToDelete->Belt.Array.size

  logAction(j`$action($id): beforeStates:$beforeCount afterStates:$afterCount added:$addedCount changed:$changedCount deleted:$deletedCount`)
  [deleteBatch(. batchToDelete), saveBatch(. batchToSave)]
  ->Js.Promise.all
  ->Js.Promise.then_(_ => Ok()->Js.Promise.resolve, _)
}

let handleAction = (
  action,
  {load, save, saveBatch, delete, deleteBatch} as primitives,
  subIdConfig,
) =>
  switch action {
  | Ignore =>
    logAction("Ignore")
    Ok()->Js.Promise.resolve

  | Create(id, state) =>
    logAction(j`Create($id, $state)`)
    save(. id, state, Init, None)
  | CreateMultiState(id, states) =>
    logAction(j`CreateMultiState($id, $states)`)
    switch states {
    | [] => Ok()->Js.Promise.resolve
    | [state] => save(. id, state, Init, None)
    | states =>
      let batch = states->Belt.Array.map(state => (id, state, None))
      saveBatch(. batch)
    }
  | CreateMany(states) =>
    let batch = states->Belt.Array.map(((id, state)) => (id, state, None))
    let statesStr = batch->Belt.Array.map(((id, state, _)) => j`($id,$state)`)
    logAction(j`CreateMany($statesStr)`)
    saveBatch(. batch) // TODO: think about using single saves with saveMode Init

  | Set(id, state) =>
    logAction(j`Set($id, $state)`)
    save(. id, state, Any, None)
  | SetMany(ids, set) =>
    let batch = ids->Belt.Array.map(id => (id, set(id), None))
    let statesStr = batch->Belt.Array.map(((id, state, _)) => j`($id,$state)`)
    logAction(j`SetMany($statesStr)`)
    saveBatch(. batch)

  | Update(id, update) => load(. id)->Js.Promise.then_(x =>
      switch x {
      | Ok(states) =>
        switch states {
        | list{} =>
          logAction(j`Update Error: No oldState for $id)`)
          Error(StaleState)->Js.Promise.resolve
        | list{oldState} =>
          let newState = oldState->update
          logAction(j`Update($id, $oldState => $newState)`)
          save(. id, newState, Overwrite, None)
        | _ =>
          logAction(j`Update Error: Multiple oldStates for $id)`)
          Error(StaleState)->Js.Promise.resolve
        }
      | Error(err) => Error(err)->Js.Promise.resolve
      }
    , _)
  | UpdateWithDefault(id, default, update) => load(. id)->Js.Promise.then_(x =>
      switch x {
      | Ok(states) =>
        switch states {
        | list{} =>
          logAction(j`UpdateWithDefault($id, default: $default)`)
          save(. id, default, Init, None)
        | list{oldState} =>
          let newState = oldState->update
          logAction(j`UpdateWithDefault($id, $oldState => $newState)`)
          save(. id, newState, Overwrite, None)
        | _ =>
          logAction(j`UpdateWithDefault Error: Multiple oldStates for $id)`)
          Error(StaleState)->Js.Promise.resolve
        }
      | Error(err) =>
        logAction(j`UpdateWithDefault Error: Couldn't load oldState(s) for $id: $err)`)
        Error(err)->Js.Promise.resolve
      }
    , _)
  | UpdateMultiState(id, update) => load(. id)->Js.Promise.then_(states =>
      switch (states, subIdConfig) {
      | (Ok(states), Some(subIdConfig)) =>
        let beforeStates = states->Belt.List.toArray
        let afterStates = beforeStates->update
        applyChanges("UpdateMultiState", id, beforeStates, afterStates, primitives, subIdConfig)

      | (Error(err), Some(_)) =>
        logAction(j`UpdateMultiState Error: Couldn't load states for $id: $err)`)
        Error(err)->Js.Promise.resolve
      | (_, None) =>
        logAction("UpdateMultiState Error: Missing SubIdConfig !")
        Error(MissingSubIdConfig)->Js.Promise.resolve
      }
    , _)
  // | UpdateManyMultiStates(ids, update) =>
  //   switch (subIdConfig) {
  //   | Some(subIdConfig) =>
  //     ids
  //     ->Belt.Array.map(id =>
  //         load(. id)
  //         ->Js.Promise.then_(
  //             fun
  //             | Ok(states) =>
  //               Some((id, states->Belt.List.toArray))->Js.Promise.resolve
  //             | Error(err) => {
  //                 logAction(
  //                   {j|UpdateMultiState Error: Couldn't load states for $id: $err)|j},
  //                 );
  //                 None->Js.Promise.resolve;
  //               },
  //             _,
  //           )
  //       )
  //     ->Js.Promise.all
  //     ->Js.Promise.then_(
  //         results =>
  //           results
  //           ->Belt.Array.keepMap(y => y)
  //           ->Belt.Array.map(((id, beforeStates)) =>
  //               applyChanges(
  //                 "UpdateManyMultiStates",
  //                 id,
  //                 beforeStates,
  //                 update(id, beforeStates),
  //                 primitives,
  //                 subIdConfig,
  //               )
  //             )
  //           ->Js.Promise.all
  //           ->Js.Promise.then_(_ => Ok()->Js.Promise.resolve, _),
  //         _,
  //       )
  //   | None =>
  //     logAction("UpdateManyMultiStates Error: Missing SubIdConfig !");
  //     Error(MissingSubIdConfig)->Js.Promise.resolve;
  //   }
  | Delete(id) =>
    logAction(j`Delete($id)`)
    delete(. id, None)
  | DeleteMany(ids) =>
    logAction(j`DeleteMany($ids)`)
    deleteBatch(. ids->Belt.Array.map(id => (id, None)))

  // TODO: add missing actions
  | _ =>
    logAction("Error: Action not yet supported !")
    Ok()->Js.Promise.resolve
  }

let actionsWithId = action =>
  switch action {
  | Ignore => []
  | Create(id, _) => [(id, action)]
  | CreateMultiState(id, _) => [(id, action)]
  | CreateMany(states) => states->Belt.Array.map(((id, state)) => (id, Create(id, state)))
  | Set(id, _) => [(id, action)]
  | SetMany(ids, set) => ids->Belt.Array.map(id => (id, Set(id, id->set)))
  | Update(id, _) => [(id, action)]
  | UpdateWithDefault(id, _, _) => [(id, action)]
  | UpdateMultiState(id, _) => [(id, action)]
  | UpdateManyMultiStates(ids, update) =>
    ids->Belt.Array.map(id => (id, UpdateMultiState(id, states => update(id, states))))
  | Delete(id) => [(id, action)]
  | DeleteMany(ids) => ids->Belt.Array.map(id => (id, Delete(id)))

  // TODO: add missing actions
  | _ =>
    logAction("Error: Action not yet supported !")
    []
  }

let groupActionsById = actions => {
  let allActionsWithId =
    actions->Belt.Array.map(action => action->actionsWithId)->Belt.Array.concatMany
  let ids = allActionsWithId->Belt.Array.map(((id, _)) => id)
  ids
  ->Belt.Set.String.fromArray
  ->Belt.Set.String.toArray
  ->Belt.Array.map(id => (
    id,
    allActionsWithId->Belt.Array.keepMap(((actionId, action)) =>
      actionId == id ? Some(action) : None
    ),
  ))
}

let handleActions = (actions, primitives, subIdConfig) => {
  let handleActionsForId = (actions, id) => {
    let actionCount = actions->Belt.Array.size
    if actionCount > 1 {
      Js.log(j`Projection.handleActions: handling $actionCount actions for id=$id`)
    }
    actions->Belt.Array.reduce(Ok()->Js.Promise.resolve, (p, action) =>
      Js.Promise.then_(_ => action->handleAction(primitives, subIdConfig), p)
    )
  }

  actions
  ->groupActionsById
  ->Belt.Array.map(((id, actions)) => actions->handleActionsForId(id))
  ->Js.Promise.all
  ->Js.Promise.then_(results => {
    let errors = results->Belt.Array.keepMap(x =>
      switch x {
      | Belt.Result.Error(err) => Some(err)
      | _ => None
      }
    )
    switch errors {
    | [] => Js.Promise.resolve()
    | errors =>
      let count = errors->Belt.Array.size
      Js.Exn.raiseError(j`Projection.handleActions failed with $count errors: $errors`)
    }
  }, _)
}
