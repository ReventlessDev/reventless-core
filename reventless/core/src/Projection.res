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

// Lazy: the message thunk (and any `stateToString` it triggers) runs only when
// debug logging is enabled, so projection actions don't serialize state on the
// hot path at the default Info level.
let logAction = makeStr => log.debugLazy(~comp="Projection", makeStr)

// ── Schema-driven state overlays ────────────────────────────────────────────
// Two things every state a projection writes carries that the domain does not
// write: the composite `@displayName` label, and a lifecycle trail entry for an
// action that moved the row's lifecycle field. Both are read off the state
// schema and applied to one JSON round trip per written state.

type overlays = {
  displayName: option<Reventless.DisplayName.displayNameSpec>,
  // (trail field, lifecycle field). A trail with no lifecycle field to follow
  // records nothing — there is no value to append.
  trail: option<(string, string)>,
}

let overlaysFor = (stateSchema: S.t<unknown>): option<overlays> => {
  let displayName = Reventless.DisplayName.getSpec(stateSchema)
  let trail = switch (
    Reventless.Lifecycle.Trail.fieldName(stateSchema),
    Reventless.Lifecycle.fieldName(stateSchema),
  ) {
  | (Some(trailField), Some(lifecycleField)) => Some((trailField, lifecycleField))
  | _ => None
  }
  displayName->Option.isNone && trail->Option.isNone ? None : Some({displayName, trail})
}

// `priorLifecycle` is what the row's lifecycle field held before the action.
// `None` where the row is created — that is a change from nothing, and it opens
// the trail. `at` is the envelope's own time, never a clock: a projection that
// read one would produce a different trail on every replay.
let applyOverlays = (
  stateDict: dict<JSON.t>,
  {displayName, trail}: overlays,
  ~priorLifecycle: option<JSON.t>,
  ~at: string,
): unit => {
  displayName->Option.forEach(spec =>
    stateDict->Dict.set(
      "displayName",
      JSON.Encode.string(Reventless.DisplayName.computeLabel(spec, stateDict)),
    )
  )
  trail->Option.forEach(((trailField, lifecycleField)) =>
    switch stateDict->Dict.get(lifecycleField) {
    | Some(value) if Some(value) != priorLifecycle =>
      stateDict->Reventless.Lifecycle.Trail.record(~field=trailField, ~state=value, ~at)
    | _ => ()
    }
  )
}

// The action shapes, once, over a lens onto whatever a state is on this path:
// a typed record encoded through sury, or JSON that already is one.
//
// Multi-state actions get the label but no trail entry: pairing a before-row
// with an after-row needs the sub-id, which is not resolved until the action is
// applied, and pairing by position would credit one row's transition to another.
let rewriteActionWith = (
  action: action<'id, 'state>,
  ~overlays: overlays,
  ~toDict: 'state => option<dict<JSON.t>>,
  ~fromDict: dict<JSON.t> => 'state,
  ~at: string,
): action<'id, 'state> => {
  // Read before the update function runs, so a projection that returns its
  // argument mutated cannot make the prior state look like the new one.
  let priorLifecycleOf = state =>
    switch overlays.trail {
    | None => None
    | Some((_, lifecycleField)) => toDict(state)->Option.flatMap(Dict.get(_, lifecycleField))
    }
  let apply = (state, ~overlays, ~priorLifecycle) =>
    switch toDict(state) {
    | None => state
    | Some(stateDict) =>
      applyOverlays(stateDict, overlays, ~priorLifecycle, ~at)
      fromDict(stateDict)
    }
  // `Set` opens a trail rather than extending one: it replaces the whole row,
  // the trail included, so there is no prior value left to compare against.
  let created = state => apply(state, ~overlays, ~priorLifecycle=None)
  let updated = (fn, state) =>
    apply(fn(state), ~overlays, ~priorLifecycle=priorLifecycleOf(state))
  let labelled = state => apply(state, ~overlays={...overlays, trail: None}, ~priorLifecycle=None)
  switch action {
  | Create(id, state) => Create(id, created(state))
  | CreateMany(pairs) => CreateMany(pairs->Array.map(((id, s)) => (id, created(s))))
  | Set(id, state) => Set(id, created(state))
  | SetMany(ids, fn) => SetMany(ids, id => created(fn(id)))
  | Update(id, fn) => Update(id, state => updated(fn, state))
  | UpdateMany(ids, fn) => UpdateMany(ids, (id, s) => updated(state => fn(id, state), s))
  | UpdateWithDefault(id, default, fn) =>
    UpdateWithDefault(id, created(default), state => updated(fn, state))
  | UpdateManyWithDefault(ids, defFn, fn) =>
    UpdateManyWithDefault(
      ids,
      id => created(defFn(id)),
      (id, s) => updated(state => fn(id, state), s),
    )
  | CreateMultiState(id, states) => CreateMultiState(id, states->Array.map(labelled))
  | UpdateMultiState(id, fn) => UpdateMultiState(id, states => states->fn->Array.map(labelled))
  | UpdateManyMultiStates(ids, fn) =>
    UpdateManyMultiStates(ids, (id, states) => fn(id, states)->Array.map(labelled))
  | Delete(_) | DeleteMany(_) | DeleteIf(_, _) | DeleteManyIf(_, _) | Ignore => action
  }
}

let rewriteAction = (
  action: action<'id, 'state>,
  ~at: string,
  stateSchema: S.t<'state>,
): action<'id, 'state> =>
  switch overlaysFor(stateSchema->S.castToUnknown) {
  | None => action
  | Some(overlays) =>
    action->rewriteActionWith(
      ~overlays,
      ~at,
      ~toDict=state => state->Reventless.Util_Sury.toJson(stateSchema)->JSON.Decode.object,
      ~fromDict=stateDict =>
        stateDict->JSON.Encode.object->Reventless.Util_Sury.fromJson(stateSchema),
    )
  }

// The trail alone, for the two callers that must not compose `displayName`.
let trailOverlays = (stateSchema: option<S.t<unknown>>): option<overlays> =>
  switch stateSchema->Option.flatMap(overlaysFor) {
  | Some({trail: Some(_)} as overlays) => Some({...overlays, displayName: None})
  | _ => None
  }

/**
The rewrite a test harness applies: the trail and nothing else. `displayName`
lives in the state schema and not in the record, so composing it would produce a
state no expectation can spell.
*/
let rewriteTrail = (
  action: action<'id, 'state>,
  ~at: string,
  stateSchema: S.t<'state>,
): action<'id, 'state> =>
  switch trailOverlays(Some(stateSchema->S.castToUnknown)) {
  | None => action
  | Some(overlays) =>
    action->rewriteActionWith(
      ~overlays,
      ~at,
      ~toDict=state => state->Reventless.Util_Sury.toJson(stateSchema)->JSON.Decode.object,
      ~fromDict=stateDict =>
        stateDict->JSON.Encode.object->Reventless.Util_Sury.fromJson(stateSchema),
    )
  }

/**
The same, for the JSON-level pipeline a deployed state-view slice assembles,
whose states are already JSON. `@displayName` is composed at save there
(`ProjectionEntryPoint_Ops.withDisplayName`).
*/
let rewriteJsonAction = (
  action: action<'id, JSON.t>,
  ~at: string,
  ~stateSchema: option<S.t<unknown>>,
): action<'id, JSON.t> =>
  switch trailOverlays(stateSchema) {
  | None => action
  | Some(overlays) =>
    action->rewriteActionWith(~overlays, ~at, ~toDict=JSON.Decode.object, ~fromDict=JSON.Encode.object)
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

  // Index the after-states by subId once instead of scanning them per
  // before-state (was O(before × after)).
  let afterBySubId = Dict.make()
  afterStates->Array.forEach(after => afterBySubId->Dict.set(after->getSubId, after))
  let changedStates = beforeStates->Array.filterMap(before =>
    switch afterBySubId->Dict.get(before->getSubId) {
    | Some(after) if after != before => Some(after)
    | _ => None
    }
  )
  let changedCount = changedStates->Array.length

  let batchToSave =
    changedStates->Array.concat(addedStates)->Array.map(state => (id, state, None))

  let deletedSubIds = beforeSubIds->Set.diff(afterSubIds)->Set.toArray
  let batchToDelete = deletedSubIds->Array.map(subId => (id, Some((subIdField, subId))))
  let deletedCount = batchToDelete->Array.length

  logAction(() =>
    `${action}(${id}): beforeStates:${beforeCount->Int.toString} afterStates:${afterCount->Int.toString} added:${addedCount->Int.toString} changed:${changedCount->Int.toString} deleted:${deletedCount->Int.toString}`
  )
  let result = await [deleteBatch(batchToDelete), saveBatch(batchToSave)]->Promise.all
  // Propagate the first storage failure instead of swallowing it — a failed
  // delete/save was previously reported as a successful projection.
  switch result->Array.find(r =>
    switch r {
    | Error(_) => true
    | Ok(_) => false
    }
  ) {
  | Some(err) => err
  | None => Ok()
  }
}

// Best-effort: a state that can't be JSON-serialized (e.g. carries a function)
// must not crash the projection just to produce a debug line. Capped at the
// shared log budget — an action line names which row changed, and a read model
// holding a large field (a plugin structure, an inline offload payload) would
// otherwise print the whole row twice, once per side of the `=>`.
let stateToString: 'a => string = state =>
  state->JSON.stringifyAny->Option.getOr("<unserializable>")->LogFormat.truncate
let statesToString: array<'a> => string = states =>
  states->Array.map(stateToString)->Array.joinUnsafe(", ")

let handleAction = async (
  ~comp="Projection",
  action,
  {QueryDb.loadStream: loadStream, save, saveBatch, delete, deleteBatch} as operations,
  subIdConfig,
) => {
  // Log each applied action at Debug with the full state it creates/changes,
  // attributed to the owning component. Debug-lazy so the state is only
  // serialized when debug logging is enabled; shadows the module-level
  // `logAction` to carry the threaded `~comp` and the `handling action:` prefix.
  let logAction = makeStr => log.debugLazy(~comp, () => `handling action: ${makeStr()}`)
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
    logAction(() => "Ignore")
    Ok()

  | Create(id, state) =>
    logAction(() => `Create(${id}, ${state->stateToString})`)
    await save(id, state, Init, None)
  | CreateMultiState(id, states) =>
    logAction(() =>
      `CreateMultiState(${id}, ${states
        ->Array.map(state => state->stateToString)
        ->Array.joinUnsafe(", ")})`
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
    logAction(() =>
      `CreateMany(${batch
        ->Array.map(((id, state, _)) => `(${id},${state->stateToString})`)
        ->Array.joinUnsafe(", ")})`
    )
    await saveBatch(batch) // TODO: think about using single saves with saveMode Init

  | Set(id, state) =>
    logAction(() => `Set(${id}, ${state->stateToString})`)
    await save(id, state, Any, None)
  | SetMany(ids, set) =>
    let batch = ids->Array.map(id => (id, set(id), None))
    logAction(() =>
      `SetMany(${batch
        ->Array.map(((id, state, _)) => `(${id},${state->stateToString})`)
        ->Array.joinUnsafe(", ")})`
    )
    await saveBatch(batch)

  | Update(id, update) =>
    switch await loadAtMost(2, id) {
    | Ok(states) =>
      switch states {
      | [] =>
        logAction(() => `Update Error: No oldState for ${id})`)
        Error(ReventlessInfra.QueryDb.StaleState)
      | [oldState] =>
        let newState = oldState->update
        logAction(() => `Update(${id}, ${oldState->stateToString} => ${newState->stateToString})`)
        await save(id, newState, Overwrite, None)
      | _ =>
        logAction(() => `Update Error: Multiple oldStates for ${id})`)
        Error(ReventlessInfra.QueryDb.StaleState)
      }
    | Error(err) => Error(err)
    }
  | UpdateWithDefault(id, default, update) =>
    switch await loadAtMost(2, id) {
    | Ok(states) =>
      switch states {
      | [] =>
        logAction(() => `UpdateWithDefault(${id}, default: ${default->stateToString})`)
        await save(id, default, Init, None)
      | [oldState] =>
        let newState = oldState->update
        logAction(() =>
          `UpdateWithDefault(${id}, ${oldState->stateToString} => ${newState->stateToString})`
        )
        await save(id, newState, Overwrite, None)
      | _ =>
        logAction(() => `UpdateWithDefault Error: Multiple oldStates for ${id})`)
        Error(ReventlessInfra.QueryDb.StaleState)
      }
    | Error(err) =>
      logAction(() =>
        `UpdateWithDefault Error: Couldn't load oldState(s) for ${id}: ${err->QueryDb.storageErrorToString})`
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
      logAction(() =>
        `UpdateMultiState Error: Couldn't load states for ${id}: ${err->QueryDb.storageErrorToString})`
      )
      Error(err)
    | (_, None) =>
      logAction(() => "UpdateMultiState Error: Missing SubIdConfig !")
      Error(ReventlessInfra.QueryDb.MissingSubIdConfig)
    }
  | Delete(id) =>
    logAction(() => `Delete(${id})`)
    await delete(id, None)
  | DeleteMany(ids) =>
    logAction(() => `DeleteMany(${ids->Array.joinUnsafe(", ")})`)
    await deleteBatch(ids->Array.map(id => (id, None)))

  // An action reaching here is one this projection engine doesn't implement.
  // Returning Ok() reported the read-model write as done while silently losing
  // it; surface a storage error instead.
  | _ =>
    logAction(() => "Error: projection action not supported")
    Error(ReventlessInfra.QueryDb.NotSavedToStorage("unsupported projection action"))
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
    logAction(() => "Error: Action not yet supported !")
    []
  }

let groupActionsById = actions => {
  let allActionsWithId = actions->Array.map(action => action->actionsWithId)->Array.flat
  // One pass into a dict keyed by id (was O(ids × actions): a filterMap over
  // every action per unique id). The id ordering is unchanged — still the sorted
  // Belt.Set order — and each group preserves the actions' original order.
  let groups = Dict.make()
  allActionsWithId->Array.forEach(((id, action)) =>
    switch groups->Dict.get(id) {
    | Some(arr) => arr->Array.push(action)
    | None => groups->Dict.set(id, [action])
    }
  )
  groups
  ->Dict.keysToArray
  ->Belt.Set.String.fromArray
  ->Belt.Set.String.toArray
  ->Array.map(id => (id, groups->Dict.getUnsafe(id)))
}

let optimizeActions = actions => {
  // [ UpdateMultiSate(f), UpdateMultiState(g), Create(..)] => [ UpdateMultiState(f(g)), Create(..) ]
  actions->Array.reduce([], (optimizedActions, action) => {
    let optimizedActionsCount = optimizedActions->Array.length
    if optimizedActionsCount == 0 {
      [action]
    } else {
      let lastAction = optimizedActions->Array.getUnsafe(optimizedActionsCount - 1)
      // Everything BEFORE the last action. `~end` is exclusive, so this must be
      // `count - 1`; using `count` kept `lastAction` in the slice while the merged
      // action was also appended, applying the last action twice.
      let previousActions = optimizedActions->Array.slice(~start=0, ~end=optimizedActionsCount - 1)

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

let handleActions = async (~comp="Projection", actions, operations, subIdConfig) => {
  let handleActionsForId = async (actions, id) => {
    let actionCount = actions->Array.length
    if actionCount > 1 {
      log.debug(
        ~comp,
        `handleActions: optimizing ${actionCount->Int.toString} actions for id=${id}`,
      )
    }

    let optimizedActions = optimizeActions(actions)
    let optimizedActionCount = optimizedActions->Array.length
    log.debug(~comp, `handleActions: id=${id} actions=${optimizedActionCount->Int.toString}`)

    // FIXME: handle errors!
    await optimizedActions->Array.reduce(Ok()->Promise.resolve, async (p, action) => {
      switch await p {
      | Ok() => ()
      | Error(err) =>
        log.error(
          ~comp,
          `storage error: ${err->Message.encode(ReventlessInfra.QueryDb.storageErrorSchema)->JSON.stringify}`,
        )
      }
      await action->handleAction(~comp, operations, subIdConfig)
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
