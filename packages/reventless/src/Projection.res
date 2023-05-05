open ReventlessSpec.Projection.Spec // FIXME: open locally
open ReventlessSpec.ReadModel.Spec // FIXME: open locally
open Belt.Result // FIXME: open locally
open QueryDb // FIXME: open locally

module Set = Belt.Set.String

module Mapping = {
  module Make = (
    Source: ReventlessSpec.Projection.Spec.Source,
    Target: ReventlessSpec.Projection.Spec.Target,
    MappingImpl: ReventlessSpec.Projection.MappingImpl
      with type sourceEvent := Source.event
      and type targetState := Target.state,
  ): (
    ReventlessSpec.Projection.Mapping
      with type targetState = Target.state
      and type sourceEvent = Source.event
      and module SourceId = Source.Id
  ) => {
    module SourceId = Source.Id
    type sourceEvent = Source.event
    type targetState = Target.state
    let map = MappingImpl.map
    let sourceEvent_decode = Source.event_decode
    let sourceEvent_encode = Source.event_encode
    let sourceName = Source.name
    let subIdConfig = Target.subIdConfig
    let targetState_encode = Target.state_encode
  }
}

module Mappings = {
  module Make = (Target: ReventlessSpec.Projection.Spec.Target) => {
    module type Mapping = ReventlessSpec.Projection.Mapping with type targetState = Target.state
  }
}

type primitives<'id, 'state> = {
  load: ReventlessSpec.QueryDb.load<'id, 'state>,
  save: ReventlessSpec.QueryDb.save<'id, 'state>,
  saveBatch: ReventlessSpec.QueryDb.saveBatch<'id, 'state>,
  delete: ReventlessSpec.QueryDb.delete<'id>,
  deleteBatch: ReventlessSpec.QueryDb.deleteBatch<'id>,
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

  logAction(
    `${action}(${id}): beforeStates:${beforeCount->Belt.Int.toString} afterStates:${afterCount->Belt.Int.toString} added:${addedCount->Belt.Int.toString} changed:${changedCount->Belt.Int.toString} deleted:${deletedCount->Belt.Int.toString}`,
  )
  [deleteBatch(. batchToDelete), saveBatch(. batchToSave)]
  ->Js.Promise.all
  ->Js.Promise2.then(_ => Ok()->Js.Promise.resolve)
}

let stateToString: 'a => string = state => state->Js.Json.stringifyAny->Belt.Option.getExn
let statesToString: array<'a> => string = states =>
  states->Belt.Array.map(stateToString)->Js.Array2.joinWith(", ")

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
    logAction(`Create(${id}, ${state->stateToString})`)
    save(. id, state, Init, None)
  | CreateMultiState(id, states) =>
    logAction(
      `CreateMultiState(${id}, ${states
        ->Belt.Array.map(state => state->stateToString)
        ->Js.Array2.joinWith(", ")})`,
    )
    switch states {
    | [] => Ok()->Js.Promise.resolve
    | [state] => save(. id, state, Init, None)
    | states =>
      let batch = states->Belt.Array.map(state => (id, state, None))
      saveBatch(. batch)
    }
  | CreateMany(states) =>
    let batch = states->Belt.Array.map(((id, state)) => (id, state, None))
    let statesStr =
      batch
      ->Belt.Array.map(((id, state, _)) => `(${id},${state->stateToString})`)
      ->Js.Array2.joinWith(", ")
    logAction(`CreateMany(${statesStr})`)
    saveBatch(. batch) // TODO: think about using single saves with saveMode Init

  | Set(id, state) =>
    logAction(`Set(${id}, ${state->stateToString})`)
    save(. id, state, Any, None)
  | SetMany(ids, set) =>
    let batch = ids->Belt.Array.map(id => (id, set(id), None))
    let statesStr =
      batch
      ->Belt.Array.map(((id, state, _)) => `(${id},${state->stateToString})`)
      ->Js.Array2.joinWith(", ")
    logAction(`SetMany(${statesStr})`)
    saveBatch(. batch)

  | Update(id, update) =>
    load(. id)->Js.Promise2.then(x =>
      switch x {
      | Ok(states) =>
        switch states {
        | [] =>
          logAction(`Update Error: No oldState for ${id})`)
          Error(ReventlessSpec.QueryDb.StaleState)->Js.Promise.resolve
        | [oldState] =>
          let newState = oldState->update
          logAction(`Update(${id}, ${oldState->stateToString} => ${newState->stateToString})`)
          save(. id, newState, Overwrite, None)
        | _ =>
          logAction(`Update Error: Multiple oldStates for ${id})`)
          Error(ReventlessSpec.QueryDb.StaleState)->Js.Promise.resolve
        }
      | Error(err) => Error(err)->Js.Promise.resolve
      }
    )
  | UpdateWithDefault(id, default, update) =>
    load(. id)->Js.Promise2.then(x =>
      switch x {
      | Ok(states) =>
        switch states {
        | [] =>
          logAction(`UpdateWithDefault(${id}, default: ${default->stateToString})`)
          save(. id, default, Init, None)
        | [oldState] =>
          let newState = oldState->update
          logAction(
            `UpdateWithDefault(${id}, ${oldState->stateToString} => ${newState->stateToString})`,
          )
          save(. id, newState, Overwrite, None)
        | _ =>
          logAction(`UpdateWithDefault Error: Multiple oldStates for ${id})`)
          Error(ReventlessSpec.QueryDb.StaleState)->Js.Promise.resolve
        }
      | Error(err) =>
        logAction(
          `UpdateWithDefault Error: Couldn't load oldState(s) for ${id}: ${err->QueryDbRuntime.storageErrorToString})`,
        )
        Error(err)->Js.Promise.resolve
      }
    )
  | UpdateMultiState(id, update) =>
    load(. id)->Js.Promise2.then(states =>
      switch (states, subIdConfig) {
      | (Ok(states), Some(subIdConfig)) =>
        let beforeStates = states
        let afterStates = beforeStates->update
        applyChanges("UpdateMultiState", id, beforeStates, afterStates, primitives, subIdConfig)

      | (Error(err), Some(_)) =>
        logAction(
          `UpdateMultiState Error: Couldn't load states for ${id}: ${err->QueryDbRuntime.storageErrorToString})`,
        )
        Error(err)->Js.Promise.resolve
      | (_, None) =>
        logAction("UpdateMultiState Error: Missing SubIdConfig !")
        Error(ReventlessSpec.QueryDb.MissingSubIdConfig)->Js.Promise.resolve
      }
    )
  // | UpdateManyMultiStates(ids, update) =>
  //   switch (subIdConfig) {
  //   | Some(subIdConfig) =>
  //     ids
  //     ->Belt.Array.map(id =>
  //         load(. id)
  //         ->Js.Promise2.then(
  //             fun
  //             | Ok(states) =>
  //               Some((id, states))->Js.Promise.resolve
  //             | Error(err) => {
  //                 logAction(
  //                   {j|UpdateMultiState Error: Couldn't load states for $id: $err)|j},
  //                 );
  //                 None->Js.Promise.resolve;
  //               },
  //           )
  //       )
  //     ->Js.Promise.all
  //     ->Js.Promise2.then(
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
  //           ->Js.Promise2.then(_ => Ok()->Js.Promise.resolve),
  //       )
  //   | None =>
  //     logAction("UpdateManyMultiStates Error: Missing SubIdConfig !");
  //     Error(MissingSubIdConfig)->Js.Promise.resolve;
  //   }
  | Delete(id) =>
    logAction(`Delete(${id})`)
    delete(. id, None)
  | DeleteMany(ids) =>
    logAction(`DeleteMany(${ids->Js.Array2.joinWith(", ")})`)
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
      Js.log(
        `Projection.handleActions: handling ${actionCount->Belt.Int.toString} actions for id=${id}`,
      )
    }
    actions->Belt.Array.reduce(Ok()->Js.Promise.resolve, (p, action) =>
      Js.Promise.then_(_ => action->handleAction(primitives, subIdConfig), p)
    )
  }

  actions
  ->groupActionsById
  ->Belt.Array.map(((id, actions)) => actions->handleActionsForId(id))
  ->Js.Promise.all
  ->Js.Promise2.then(results => {
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
      Js.Exn.raiseError(
        `Projection.handleActions failed with ${count->Belt.Int.toString} errors: ${errors
          ->Belt.Array.map(QueryDbRuntime.storageErrorToString)
          ->Js.Array2.joinWith(",")}`,
      )
    }
  })
}
