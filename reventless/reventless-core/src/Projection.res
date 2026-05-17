open Reventless.Projection // FIXME: open locally
open Reventless.ReadModel // FIXME: open locally
// Belt.Result removed — Ok/Error are global in RescriptCore

module Set = Belt.Set.String

let log = Logger.fromEnv()

module Mapping = {
  module MakeGenericSource = (Mapping: Reventless.Projection.Mapping): (
    Mapper.GenericSource with type t = Mapping.sourceEvent
  ) => {
    let name = Mapping.sourceName
    type t = Mapping.sourceEvent
    let decode' = json => json->Message.decodeEvent'(S.string, Mapping.sourceEventSchema)
  }
}

let logAction = str => log.debug(~comp="Projection", str)

// ── @displayName overlay ────────────────────────────────────────────────────
// When a read model's state schema carries DisplayName metadata, every state
// written by a projection action gets its [displayName] field overwritten with
// the composite label derived from the annotated source fields. The overlay
// encodes via sury, mutates the JSON dict, and parses back — unlocks fine
// work on partial/option fields without duplicating the record shape here.

let overlayDisplayName = (
  state: 'state,
  stateSchema: S.t<'state>,
  spec: Reventless.DisplayName.displayNameSpec,
): 'state => {
  let json = state->Reventless.Util_Sury.toJson(stateSchema)
  switch json->JSON.Decode.object {
  | None => state
  | Some(stateDict) =>
    let label = Reventless.DisplayName.computeLabel(spec, stateDict)
    stateDict->Dict.set("displayName", JSON.Encode.string(label))
    stateDict->JSON.Encode.object->Reventless.Util_Sury.fromJson(stateSchema)
  }
}

let rewriteAction = (
  action: action<'id, 'state>,
  stateSchema: S.t<'state>,
): action<'id, 'state> =>
  switch Reventless.DisplayName.getSpec(stateSchema->S.castToUnknown) {
  | None => action
  | Some(spec) =>
    let overlay = state => overlayDisplayName(state, stateSchema, spec)
    switch action {
    | Create(id, state) => Create(id, overlay(state))
    | CreateMany(pairs) => CreateMany(pairs->Array.map(((id, s)) => (id, overlay(s))))
    | Set(id, state) => Set(id, overlay(state))
    | SetMany(ids, fn) => SetMany(ids, id => overlay(fn(id)))
    | Update(id, fn) => Update(id, state => overlay(fn(state)))
    | UpdateMany(ids, fn) => UpdateMany(ids, (id, s) => overlay(fn(id, s)))
    | UpdateWithDefault(id, default, fn) =>
      UpdateWithDefault(id, overlay(default), state => overlay(fn(state)))
    | UpdateManyWithDefault(ids, defFn, fn) =>
      UpdateManyWithDefault(ids, id => overlay(defFn(id)), (id, s) => overlay(fn(id, s)))
    | CreateMultiState(id, states) => CreateMultiState(id, states->Array.map(overlay))
    | UpdateMultiState(id, fn) =>
      UpdateMultiState(id, states => states->fn->Array.map(overlay))
    | UpdateManyMultiStates(ids, fn) =>
      UpdateManyMultiStates(ids, (id, states) => fn(id, states)->Array.map(overlay))
    | Delete(_) | DeleteMany(_) | DeleteIf(_, _) | DeleteManyIf(_, _) | Ignore => action
    }
  }

let applyChanges = async (
  action,
  id,
  beforeStates,
  afterStates,
  {QueryDb.saveBatch: saveBatch, deleteBatch},
  {subIdField, getSubId},
) => {
  let beforeCount = beforeStates->Array.length
  let beforeSubIds = beforeStates->Array.map(state => state->getSubId)->Set.fromArray

  let afterCount = afterStates->Array.length
  let afterSubIds = afterStates->Array.map(state => state->getSubId)->Set.fromArray

  let addedSubIds = afterSubIds->Set.diff(beforeSubIds)
  let addedStates = afterStates->Array.filter(state => addedSubIds->Set.has(state->getSubId))
  let addedCount = addedStates->Array.length

  let changedStates = beforeStates->Array.filterMap(before => {
    let beforeSubId = before->getSubId
    afterStates->Array.find(after => after->getSubId == beforeSubId && after != before)
  })
  let changedCount = changedStates->Array.length

  let batchToSave =
    changedStates->Array.concat(addedStates)->Array.map(state => (id, state, None))

  let deletedSubIds = beforeSubIds->Set.diff(afterSubIds)->Set.toArray
  let batchToDelete = deletedSubIds->Array.map(subId => (id, Some((subIdField, subId))))
  let deletedCount = batchToDelete->Array.length

  logAction(
    `${action}(${id}): beforeStates:${beforeCount->Int.toString} afterStates:${afterCount->Int.toString} added:${addedCount->Int.toString} changed:${changedCount->Int.toString} deleted:${deletedCount->Int.toString}`,
  )
  let result = await [deleteBatch(batchToDelete), saveBatch(batchToSave)]->Promise.all
  switch result {
  | _ => Ok() // TODO: Error handling
  }
}

let stateToString: 'a => string = state => state->JSON.stringifyAny->Option.getOrThrow
let statesToString: array<'a> => string = states =>
  states->Array.map(stateToString)->Array.joinUnsafe(", ")

let handleAction = async (
  action,
  {QueryDb.loadStream: loadStream, save, saveBatch, delete, deleteBatch} as operations,
  subIdConfig,
) => {
  let loadAtMost = (n, id) =>
    loadStream(id)
    ->Stream.take(n)
    ->Stream.runCollect
    ->Effect.map(states => Ok(states))
    ->Effect.catchAll(e => Effect.succeed(Error(e)))
    ->Effect.runPromise
  let loadAll = id =>
    loadStream(id)
    ->Stream.runCollect
    ->Effect.map(states => Ok(states))
    ->Effect.catchAll(e => Effect.succeed(Error(e)))
    ->Effect.runPromise
  switch action {
  | Ignore =>
    logAction("Ignore")
    Ok()

  | Create(id, state) =>
    logAction(`Create(${id}, ${state->stateToString})`)
    await save(id, state, Init, None)
  | CreateMultiState(id, states) =>
    logAction(
      `CreateMultiState(${id}, ${states
        ->Array.map(state => state->stateToString)
        ->Array.joinUnsafe(", ")})`,
    )
    switch states {
    | [] => Ok()
    | [state] => await save(id, state, Init, None)
    | states =>
      let batch = states->Array.map(state => (id, state, None))
      await saveBatch(batch)
    }
  | CreateMany(states) =>
    let batch = states->Array.map(((id, state)) => (id, state, None))
    let statesStr =
      batch
      ->Array.map(((id, state, _)) => `(${id},${state->stateToString})`)
      ->Array.joinUnsafe(", ")
    logAction(`CreateMany(${statesStr})`)
    await saveBatch(batch) // TODO: think about using single saves with saveMode Init

  | Set(id, state) =>
    logAction(`Set(${id}, ${state->stateToString})`)
    await save(id, state, Any, None)
  | SetMany(ids, set) =>
    let batch = ids->Array.map(id => (id, set(id), None))
    let statesStr =
      batch
      ->Array.map(((id, state, _)) => `(${id},${state->stateToString})`)
      ->Array.joinUnsafe(", ")
    logAction(`SetMany(${statesStr})`)
    await saveBatch(batch)

  | Update(id, update) =>
    switch await loadAtMost(2, id) {
    | Ok(states) =>
      switch states {
      | [] =>
        logAction(`Update Error: No oldState for ${id})`)
        Error(ReventlessInfra.QueryDb.StaleState)
      | [oldState] =>
        let newState = oldState->update
        logAction(`Update(${id}, ${oldState->stateToString} => ${newState->stateToString})`)
        await save(id, newState, Overwrite, None)
      | _ =>
        logAction(`Update Error: Multiple oldStates for ${id})`)
        Error(ReventlessInfra.QueryDb.StaleState)
      }
    | Error(err) => Error(err)
    }
  | UpdateWithDefault(id, default, update) =>
    log.debug(~comp="Projection", `UpdateWithDefault(${id}, loading ...`)
    switch await loadAtMost(2, id) {
    | Ok(states) =>
      switch states {
      | [] =>
        logAction(`UpdateWithDefault(${id}, default: ${default->stateToString})`)
        await save(id, default, Init, None)
      | [oldState] =>
        let newState = oldState->update
        logAction(
          `UpdateWithDefault(${id}, ${oldState->stateToString} => ${newState->stateToString})`,
        )
        await save(id, newState, Overwrite, None)
      | _ =>
        logAction(`UpdateWithDefault Error: Multiple oldStates for ${id})`)
        Error(ReventlessInfra.QueryDb.StaleState)
      }
    | Error(err) =>
      logAction(
        `UpdateWithDefault Error: Couldn't load oldState(s) for ${id}: ${err->QueryDb.storageErrorToString})`,
      )
      Error(err)
    }
  | UpdateMultiState(id, update) =>
    switch (await loadAll(id), subIdConfig) {
    | (Ok(states), Some(subIdConfig)) =>
      let beforeStates = states
      let afterStates = beforeStates->update
      await applyChanges("UpdateMultiState", id, beforeStates, afterStates, operations, subIdConfig)

    | (Error(err), Some(_)) =>
      logAction(
        `UpdateMultiState Error: Couldn't load states for ${id}: ${err->QueryDb.storageErrorToString})`,
      )
      Error(err)
    | (_, None) =>
      logAction("UpdateMultiState Error: Missing SubIdConfig !")
      Error(ReventlessInfra.QueryDb.MissingSubIdConfig)
    }
  | Delete(id) =>
    logAction(`Delete(${id})`)
    await delete(id, None)
  | DeleteMany(ids) =>
    logAction(`DeleteMany(${ids->Array.joinUnsafe(", ")})`)
    await deleteBatch(ids->Array.map(id => (id, None)))

  // TODO: add missing actions
  | _ =>
    logAction("Error: Action not yet supported !")
    Ok()
  }
}

let actionsWithId = action =>
  switch action {
  | Ignore => []
  | Create(id, _) => [(id, action)]
  | CreateMultiState(id, _) => [(id, action)]
  | CreateMany(states) => states->Array.map(((id, state)) => (id, Create(id, state)))
  | Set(id, _) => [(id, action)]
  | SetMany(ids, set) => ids->Array.map(id => (id, Set(id, id->set)))
  | Update(id, _) => [(id, action)]
  | UpdateWithDefault(id, _, _) => [(id, action)]
  | UpdateMultiState(id, _) => [(id, action)]
  | UpdateManyMultiStates(ids, update) =>
    ids->Array.map(id => (id, UpdateMultiState(id, states => update(id, states))))
  | Delete(id) => [(id, action)]
  | DeleteMany(ids) => ids->Array.map(id => (id, Delete(id)))

  // TODO: add missing actions
  | _ =>
    logAction("Error: Action not yet supported !")
    []
  }

let groupActionsById = actions => {
  let allActionsWithId = actions->Array.map(action => action->actionsWithId)->Array.flat
  let ids = allActionsWithId->Array.map(((id, _)) => id)
  ids
  ->Belt.Set.String.fromArray
  ->Belt.Set.String.toArray
  ->Array.map(id => (
    id,
    allActionsWithId->Array.filterMap(((actionId, action)) => actionId == id ? Some(action) : None),
  ))
}

let optimizeActions = actions => {
  // [ UpdateMultiSate(f), UpdateMultiState(g), Create(..)] => [ UpdateMultiState(f(g)), Create(..) ]
  actions->Array.reduce([], (optimizedActions, action) => {
    let optimizedActionsCount = optimizedActions->Array.length
    if optimizedActionsCount == 0 {
      [action]
    } else {
      let lastAction = optimizedActions->Array.getUnsafe(optimizedActionsCount - 1)
      let previousActions = if optimizedActionsCount == 1 {
        []
      } else {
        optimizedActions->Array.slice(~start=0, ~end=optimizedActionsCount)
      }

      switch (lastAction, action) {
      // SINGLE STATES
      | (Create(id1, state1), Update(id2, f)) if id1 == id2 =>
        previousActions->Array.concat([Create(id1, f(state1))])
      | (Create(id1, state1), UpdateWithDefault(id2, _defaultState2, f)) if id1 == id2 =>
        previousActions->Array.concat([Create(id1, f(state1))])
      | (Update(id1, f), Update(id2, g)) if id1 == id2 =>
        previousActions->Array.concat([Update(id1, state => g(f(state)))])
      | (UpdateWithDefault(id1, defaultState1, f), UpdateWithDefault(id2, _defaultState2, g))
        if id1 == id2 =>
        previousActions->Array.concat([
          UpdateWithDefault(id1, g(defaultState1), state => g(f(state))),
        ])
      | (Update(id1, f), UpdateWithDefault(id2, defaultState2, g)) if id1 == id2 =>
        previousActions->Array.concat([
          UpdateWithDefault(
            id1,
            /* if no state exists before the first upate, it is ignored */
            defaultState2,
            state => g(f(state)),
          ),
        ])
      | (UpdateWithDefault(id1, defaultState1, f), Update(id2, g)) if id1 == id2 =>
        previousActions->Array.concat([
          UpdateWithDefault(id1, g(defaultState1), state => g(f(state))),
        ])
      | (UpdateWithDefault(id1, defaultState1, f), Create(id2, _state2)) if id1 == id2 =>
        log.warn(~comp="Projection", `optimizing Create after UpdateWithDefault for id=${id1}, ignoring the Create`)
        previousActions->Array.concat([UpdateWithDefault(id1, defaultState1, f)])
      | (Create(id1, state1), Create(id2, state2)) if id1 == id2 =>
        log.warn(
          ~comp="Projection",
          `optimizing 2 sequential Create for id=${id1}, ignoring second: ${state2->JSON.stringifyAny->Option.getOr("?")}`,
        )
        previousActions->Array.concat([Create(id1, state1)])
      | (Create(id1, state1), Delete(id2)) if id1 == id2 =>
        log.warn(
          ~comp="Projection",
          `optimizing Delete after Create for id=${id1}, ignoring Create: ${state1->JSON.stringifyAny->Option.getOr("?")}`,
        )
        previousActions->Array.concat([Delete(id1)])
      | (Update(id1, _f), Delete(id2)) if id1 == id2 =>
        log.warn(~comp="Projection", `optimizing Delete after Update for id=${id1}, ignoring the Update`)
        previousActions->Array.concat([Delete(id1)])
      | (UpdateWithDefault(id1, _defaultState1, _f), Delete(id2)) if id1 == id2 =>
        log.warn(~comp="Projection", `optimizing Delete after UpdateWithDefault for id=${id1}, ignoring the UpdateWithDefault`)
        previousActions->Array.concat([Delete(id1)])
      | (Delete(id1), Create(id2, state2)) if id1 == id2 =>
        previousActions->Array.concat([Set(id1, state2)])
      | (Create(id1, state1), Set(id2, state2)) if id1 == id2 =>
        log.warn(
          ~comp="Projection",
          `optimizing Set after Create for id=${id1}, ignoring Create: ${state1->JSON.stringifyAny->Option.getOr("?")}`,
        )
        previousActions->Array.concat([Set(id1, state2)])
      | (Update(id1, _f), Set(id2, state2)) if id1 == id2 =>
        log.warn(~comp="Projection", `optimizing Set after Update for id=${id1}, ignoring the Update`)
        previousActions->Array.concat([Set(id1, state2)])
      | (UpdateWithDefault(id1, _defaultState1, _f), Set(id2, state2)) if id1 == id2 =>
        log.warn(~comp="Projection", `optimizing Set after UpdateWithDefault for id=${id1}, ignoring the UpdateWithDefault`)
        previousActions->Array.concat([Set(id1, state2)])
      // MULTI STATES
      /*
      | (CreateMultiState(id1, states1), UpdateMultiState(id2, f)) if id1 == id2 =>
        THIS IS FALSE: previousActions->Array.concat([CreateMultiState(id1, f(states1))])
        suggestion: UpdateMultiState with following updateFunction:
            - apply f to states1 and states of UpdateMultiState separately
            - concat unique states of both results
 */
      | (UpdateMultiState(id1, f), UpdateMultiState(id2, g)) if id1 == id2 =>
        previousActions->Array.concat([UpdateMultiState(id1, state => g(f(state)))])
      /*
      | (UpdateMultiState(id1, _f), CreateMultiState(id2, states2)) if id1 == id2 =>
        Console..warn(
          "optimizing CreateMultiState after UpdateMultiState, therefore ignoring the UpdateMultiState",
        )
        THIS IS FALSE: previousActions->Array.concat([CreateMultiState(id1, states2)])
        suggestion: UpdateMultiState with following updateFunction:
            - apply f to states of UpdateMultiState 
            - concat unique states of update results and states2
            - if duplicates exist, prefer states2
 */
      /*
      | (CreateMultiState(id1, states1), CreateMultiState(id2, states2)) if id1 == id2 =>
        Console..warn2(
          "optimizing 2 sequential CreateMultiState actions, therefore ignoring the first one:",
          states1->JSON.stringifyAny,
        )
        THIS IS FALSE: previousActions->Array.concat([CreateMultiState(id1, states2)])
        suggestion: CreateMultiState with following updateFunction:
            - concatenate states1 & states2
            - if duplicates exist, prefer states2
 */
      | (lastAction, action) =>
        // any other action will be just appended
        log.warn(
          ~comp="Projection",
          `actions not optimized: ${lastAction->JSON.stringifyAny->Option.getOr("?")} + ${action->JSON.stringifyAny->Option.getOr("?")}`,
        )
        optimizedActions->Array.concat([action])
      }
    }
  })
}

let handleActions = async (actions, operations, subIdConfig) => {
  let handleActionsForId = async (actions, id) => {
    let actionCount = actions->Array.length
    if actionCount > 1 {
      log.debug(
        ~comp="Projection",
        `handleActions: optimizing ${actionCount->Int.toString} actions for id=${id}`,
      )
    }

    let optimizedActions = optimizeActions(actions)
    let optimizedActionCount = optimizedActions->Array.length
    log.info(~comp="Projection", `handleActions: id=${id} actions=${optimizedActionCount->Int.toString}`)

    // FIXME: handle errors!
    await optimizedActions->Array.reduce(Ok()->Promise.resolve, async (p, action) => {
      switch await p {
      | Ok() => ()
      | Error(err) =>
        log.error(
          ~comp="Projection",
          `storage error: ${err->Message.encode(ReventlessInfra.QueryDb.storageErrorSchema)->JSON.stringify}`,
        )
      }
      await action->handleAction(operations, subIdConfig)
    })
  }

  let results = await actions
  ->groupActionsById
  ->Array.map(((id, actions)) => actions->handleActionsForId(id))
  ->Promise.all
  let errors = results->Array.filterMap(x =>
    switch x {
    | Error(err) => Some(err)
    | _ => None
    }
  )
  switch errors {
  | [] => ()
  | errors =>
    let count = errors->Array.length
    JsError.throwWithMessage(
      `Projection.handleActions failed with ${count->Int.toString} errors: ${errors
        ->Array.map(QueryDb.storageErrorToString)
        ->Array.joinUnsafe(",")}`,
    )
  }
}
