open Reventless.Projection // FIXME: open locally
open Reventless.ReadModel // FIXME: open locally
// Belt.Result removed — Ok/Error are global in RescriptCore

module Set = Belt.Set.String

let log = Logger.fromEnv()

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
  displayName?: Reventless.DisplayName.displayNameSpec,
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
  displayName->Option.isNone && trail->Option.isNone ? None : Some({?displayName, trail})
}

// `priorLifecycle` is what the row's lifecycle field held before the action.
// `None` where the row is created — that is a change from nothing, and it opens
// the trail. `at` is the envelope's own time, never a clock: a projection that
// read one would produce a different trail on every replay.
let applyOverlays = (
  stateDict: dict<JSON.t>,
  {?displayName, trail}: overlays,
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
  let updated = (fn, state) => apply(fn(state), ~overlays, ~priorLifecycle=priorLifecycleOf(state))
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

let rewriteAction = (action: action<'id, 'state>, ~at: string, stateSchema: S.t<'state>): action<
  'id,
  'state,
> =>
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
  | Some({trail: Some(_)} as overlays) => Some({...overlays, displayName: ?None})
  | _ => None
  }

/**
The rewrite a test harness applies: the trail and nothing else. `displayName`
lives in the state schema and not in the record, so composing it would produce a
state no expectation can spell.
*/
let rewriteTrail = (action: action<'id, 'state>, ~at: string, stateSchema: S.t<'state>): action<
  'id,
  'state,
> =>
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
    action->rewriteActionWith(
      ~overlays,
      ~at,
      ~toDict=JSON.Decode.object,
      ~fromDict=JSON.Encode.object,
    )
  }

// ── What an applied action changed ─────────────────────────────────────────
// A caller that wants to know which rows an action changed passes `~onChange`;
// it is called once per row written or removed, after the store said yes.

type changeKind =
  | Created
  | Changed
  | Removed

/** An event that led to a change: its message id, its flow, and the entity it
    is about (an aggregate's id and name, or a DCB event's tag value and key). */
type changeSource = {
  msgId: string,
  correlationId?: string,
  entityId?: string,
  entityType?: string,
}

/** One row a projection created, changed or removed. `before` is there where the
    row was loaded first; `Set` and `Delete` write without loading, so theirs is
    absent. `sources` are the events whose actions were applied to the row, all of
    them when several actions on it were merged. */
type rowChange<'state> = {
  key: string,
  subId?: string,
  kind: changeKind,
  before?: 'state,
  after?: 'state,
  sources: array<changeSource>,
}

/** An action with the events it came from. */
type sourced<'id, 'state> = {action: action<'id, 'state>, sources: array<changeSource>}

/** Both lists, each source once. */
let mergeSources = (a: array<changeSource>, b: array<changeSource>): array<changeSource> =>
  a->Array.concat(b->Array.filter(s => !(a->Array.some(other => other.msgId == s.msgId))))

let applyChanges = async (
  action,
  id,
  beforeStates,
  afterStates,
  {QueryDb.saveBatch: saveBatch, deleteBatch},
  {subIdField, getSubId},
  ~onRow: (~subId: string, ~before: option<'state>, ~after: option<'state>, changeKind) => unit=(
    ~subId as _,
    ~before as _,
    ~after as _,
    _,
  ) => (),
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

  let batchToSave = changedStates->Array.concat(addedStates)->Array.map(state => (id, state, None))

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
  | None =>
    let beforeBySubId = Dict.make()
    beforeStates->Array.forEach(before => beforeBySubId->Dict.set(before->getSubId, before))
    afterStates->Array.forEach(after => {
      let subId = after->getSubId
      switch beforeBySubId->Dict.get(subId) {
      | None => onRow(~subId, ~before=None, ~after=Some(after), Created)
      | Some(before) if before != after =>
        onRow(~subId, ~before=Some(before), ~after=Some(after), Changed)
      | Some(_) => ()
      }
    })
    deletedSubIds->Array.forEach(subId =>
      onRow(~subId, ~before=beforeBySubId->Dict.get(subId), ~after=None, Removed)
    )
    Ok()
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

let applyAction = async (
  ~comp="Projection",
  ~sources: array<changeSource>=[],
  ~onChange: option<rowChange<'state> => unit>=?,
  action,
  {QueryDb.loadStream: loadStream, save, saveBatch, delete, deleteBatch} as operations,
  subIdConfig,
) => {
  // A listener that throws is noted and skipped: the row is already written.
  let report = (~key, ~subId=?, ~before=?, ~after=?, kind) =>
    onChange->Option.forEach(f =>
      try f({key, ?subId, kind, ?before, ?after, sources}) catch {
      | exn =>
        log.warn(
          ~comp,
          `a view-change listener failed: ${exn
            ->JsExn.fromException
            ->Option.flatMap(JsExn.message)
            ->Option.getOr("unknown")}`,
        )
      }
    )
  let subIdOf = state => subIdConfig->Option.map(({getSubId}) => getSubId(state))
  // Reports only what the store accepted.
  let after = (result, reportAll) => {
    switch (result, onChange) {
    | (Ok(), Some(_)) => reportAll()
    | _ => ()
    }
    result
  }
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
    (await save(id, state, Init, None))->after(() => report(~key=id, ~after=state, Created))
  | CreateMultiState(id, states) =>
    logAction(() =>
      `CreateMultiState(${id}, ${states
        ->Array.map(state => state->stateToString)
        ->Array.joinUnsafe(", ")})`
    )
    let reportAll = () =>
      states->Array.forEach(state => report(~key=id, ~subId=?subIdOf(state), ~after=state, Created))
    switch states {
    | [] => Ok()
    | [state] => (await save(id, state, Init, None))->after(reportAll)
    | states =>
      let batch = states->Array.map(state => (id, state, None))
      (await saveBatch(batch))->after(reportAll)
    }
  | CreateMany(states) =>
    let batch = states->Array.map(((id, state)) => (id, state, None))
    logAction(() =>
      `CreateMany(${batch
        ->Array.map(((id, state, _)) => `(${id},${state->stateToString})`)
        ->Array.joinUnsafe(", ")})`
    )
    // TODO: think about using single saves with saveMode Init
    (await saveBatch(batch))->after(() =>
      batch->Array.forEach(((id, state, _)) => report(~key=id, ~after=state, Created))
    )

  | Set(id, state) =>
    logAction(() => `Set(${id}, ${state->stateToString})`)
    (await save(id, state, Any, None))->after(() => report(~key=id, ~after=state, Changed))
  | SetMany(ids, set) =>
    let batch = ids->Array.map(id => (id, set(id), None))
    logAction(() =>
      `SetMany(${batch
        ->Array.map(((id, state, _)) => `(${id},${state->stateToString})`)
        ->Array.joinUnsafe(", ")})`
    )
    (await saveBatch(batch))->after(() =>
      batch->Array.forEach(((id, state, _)) => report(~key=id, ~after=state, Changed))
    )

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
        (await save(id, newState, Overwrite, None))->after(() =>
          if newState != oldState {
            report(~key=id, ~before=oldState, ~after=newState, Changed)
          }
        )
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
        (await save(id, default, Init, None))->after(() => report(~key=id, ~after=default, Created))
      | [oldState] =>
        let newState = oldState->update
        logAction(() =>
          `UpdateWithDefault(${id}, ${oldState->stateToString} => ${newState->stateToString})`
        )
        (await save(id, newState, Overwrite, None))->after(() =>
          if newState != oldState {
            report(~key=id, ~before=oldState, ~after=newState, Changed)
          }
        )
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
      await applyChanges(
        "UpdateMultiState",
        id,
        beforeStates,
        afterStates,
        operations,
        subIdConfig,
        ~onRow=(~subId, ~before, ~after, kind) => report(~key=id, ~subId, ~before?, ~after?, kind),
      )

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
    (await delete(id, None))->after(() => report(~key=id, Removed))
  | DeleteMany(ids) =>
    logAction(() => `DeleteMany(${ids->Array.joinUnsafe(", ")})`)
    (await deleteBatch(ids->Array.map(id => (id, None))))->after(() =>
      ids->Array.forEach(id => report(~key=id, Removed))
    )

  // An action reaching here is one this projection engine doesn't implement.
  // Returning Ok() reported the read-model write as done while silently losing
  // it; surface a storage error instead.
  | _ =>
    logAction(() => "Error: projection action not supported")
    Error(ReventlessInfra.QueryDb.NotSavedToStorage("unsupported projection action"))
  }
}

/** Applies one action to the store, its rows stamped with the last of its sources as their
    `_change` ([RowChange]). Without a source the rows are written unstamped. */
let handleAction = (
  ~comp="Projection",
  ~sources: array<changeSource>=[],
  ~onChange: option<rowChange<'state> => unit>=?,
  action,
  operations,
  subIdConfig,
) => {
  let apply = () => applyAction(~comp, ~sources, ~onChange?, action, operations, subIdConfig)
  switch sources->Array.at(-1) {
  | Some(s) =>
    RowChange.during(
      {
        flow: ?s.correlationId,
        msgId: s.msgId,
        at: Date.make()->Date.toISOString,
      },
      apply,
    )
  | None => apply()
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

let groupSourcedById = (actions: array<sourced<'id, 'state>>) => {
  let allActionsWithId =
    actions
    ->Array.map(({action, sources}) =>
      action->actionsWithId->Array.map(((id, action)) => (id, {action, sources}))
    )
    ->Array.flat
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

let groupActionsById = actions =>
  actions
  ->Array.map(action => {action, sources: []})
  ->groupSourcedById
  ->Array.map(((id, group)) => (id, group->Array.map(s => s.action)))

// The one action two consecutive actions on one id amount to, or `None` when they
// stay two.
let mergeActions = (lastAction, action) =>
  switch (lastAction, action) {
  // SINGLE STATES
  | (Create(id1, state1), Update(id2, f)) if id1 == id2 => Some(Create(id1, f(state1)))
  | (Create(id1, state1), UpdateWithDefault(id2, _defaultState2, f)) if id1 == id2 =>
    Some(Create(id1, f(state1)))
  | (Update(id1, f), Update(id2, g)) if id1 == id2 => Some(Update(id1, state => g(f(state))))
  | (UpdateWithDefault(id1, defaultState1, f), UpdateWithDefault(id2, _defaultState2, g))
    if id1 == id2 =>
    Some(UpdateWithDefault(id1, g(defaultState1), state => g(f(state))))
  | (Update(id1, f), UpdateWithDefault(id2, defaultState2, g)) if id1 == id2 =>
    Some(
      UpdateWithDefault(
        id1,
        /* if no state exists before the first upate, it is ignored */
        defaultState2,
        state => g(f(state)),
      ),
    )
  | (UpdateWithDefault(id1, defaultState1, f), Update(id2, g)) if id1 == id2 =>
    Some(UpdateWithDefault(id1, g(defaultState1), state => g(f(state))))
  | (UpdateWithDefault(id1, defaultState1, f), Create(id2, _state2)) if id1 == id2 =>
    log.warn(
      ~comp="Projection",
      `optimizing Create after UpdateWithDefault for id=${id1}, ignoring the Create`,
    )
    Some(UpdateWithDefault(id1, defaultState1, f))
  | (Create(id1, state1), Create(id2, state2)) if id1 == id2 =>
    log.warn(
      ~comp="Projection",
      `optimizing 2 sequential Create for id=${id1}, ignoring second: ${state2
        ->JSON.stringifyAny
        ->Option.getOr("?")}`,
    )
    Some(Create(id1, state1))
  | (Create(id1, state1), Delete(id2)) if id1 == id2 =>
    log.warn(
      ~comp="Projection",
      `optimizing Delete after Create for id=${id1}, ignoring Create: ${state1
        ->JSON.stringifyAny
        ->Option.getOr("?")}`,
    )
    Some(Delete(id1))
  | (Update(id1, _f), Delete(id2)) if id1 == id2 =>
    log.warn(
      ~comp="Projection",
      `optimizing Delete after Update for id=${id1}, ignoring the Update`,
    )
    Some(Delete(id1))
  | (UpdateWithDefault(id1, _defaultState1, _f), Delete(id2)) if id1 == id2 =>
    log.warn(
      ~comp="Projection",
      `optimizing Delete after UpdateWithDefault for id=${id1}, ignoring the UpdateWithDefault`,
    )
    Some(Delete(id1))
  | (Delete(id1), Create(id2, state2)) if id1 == id2 => Some(Set(id1, state2))
  | (Create(id1, state1), Set(id2, state2)) if id1 == id2 =>
    log.warn(
      ~comp="Projection",
      `optimizing Set after Create for id=${id1}, ignoring Create: ${state1
        ->JSON.stringifyAny
        ->Option.getOr("?")}`,
    )
    Some(Set(id1, state2))
  | (Update(id1, _f), Set(id2, state2)) if id1 == id2 =>
    log.warn(~comp="Projection", `optimizing Set after Update for id=${id1}, ignoring the Update`)
    Some(Set(id1, state2))
  | (UpdateWithDefault(id1, _defaultState1, _f), Set(id2, state2)) if id1 == id2 =>
    log.warn(
      ~comp="Projection",
      `optimizing Set after UpdateWithDefault for id=${id1}, ignoring the UpdateWithDefault`,
    )
    Some(Set(id1, state2))
  // MULTI STATES
  /*
      | (CreateMultiState(id1, states1), UpdateMultiState(id2, f)) if id1 == id2 =>
        THIS IS FALSE: previousActions->Array.concat([CreateMultiState(id1, f(states1))])
        suggestion: UpdateMultiState with following updateFunction:
            - apply f to states1 and states of UpdateMultiState separately
            - concat unique states of both results
 */
  | (UpdateMultiState(id1, f), UpdateMultiState(id2, g)) if id1 == id2 =>
    Some(UpdateMultiState(id1, state => g(f(state))))
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
      `actions not optimized: ${lastAction->JSON.stringifyAny->Option.getOr("?")} + ${action
        ->JSON.stringifyAny
        ->Option.getOr("?")}`,
    )
    None
  }

// [ UpdateMultiSate(f), UpdateMultiState(g), Create(..)] => [ UpdateMultiState(f(g)), Create(..) ]
// A merged action keeps the sources of both.
let optimizeSourced = (actions: array<sourced<'id, 'state>>): array<sourced<'id, 'state>> =>
  actions->Array.reduce([], (optimized, next) => {
    let count = optimized->Array.length
    if count == 0 {
      [next]
    } else {
      let last = optimized->Array.getUnsafe(count - 1)
      // Everything BEFORE the last action. `~end` is exclusive, so this must be
      // `count - 1`; using `count` kept the last action in the slice while the
      // merged action was also appended, applying it twice.
      let previous = optimized->Array.slice(~start=0, ~end=count - 1)
      switch mergeActions(last.action, next.action) {
      | Some(action) =>
        previous->Array.concat([{action, sources: mergeSources(last.sources, next.sources)}])
      | None => optimized->Array.concat([next])
      }
    }
  })

let optimizeActions = actions =>
  actions->Array.map(action => {action, sources: []})->optimizeSourced->Array.map(s => s.action)

/** `handleActions` for actions that carry the events they came from, so each
    row change can name them. */
let handleSourcedActions = async (
  ~comp="Projection",
  ~onChange=?,
  actions: array<sourced<string, 'state>>,
  operations,
  subIdConfig,
) => {
  let handleActionsForId = async (actions, id) => {
    let actionCount = actions->Array.length
    if actionCount > 1 {
      log.debug(
        ~comp,
        `handleActions: optimizing ${actionCount->Int.toString} actions for id=${id}`,
      )
    }

    let optimizedActions = optimizeSourced(actions)
    let optimizedActionCount = optimizedActions->Array.length
    log.debug(~comp, `handleActions: id=${id} actions=${optimizedActionCount->Int.toString}`)

    // FIXME: handle errors!
    await optimizedActions->Array.reduce(Ok()->Promise.resolve, async (p, {action, sources}) => {
      switch await p {
      | Ok() => ()
      | Error(err) =>
        log.error(
          ~comp,
          `storage error: ${err
            ->Message.encode(ReventlessInfra.QueryDb.storageErrorSchema)
            ->JSON.stringify}`,
        )
      }
      await action->handleAction(~comp, ~sources, ~onChange?, operations, subIdConfig)
    })
  }

  let results = await actions
  ->groupSourcedById
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

let handleActions = (~comp="Projection", ~onChange=?, actions, operations, subIdConfig) =>
  handleSourcedActions(
    ~comp,
    ~onChange?,
    actions->Array.map(action => {action, sources: []}),
    operations,
    subIdConfig,
  )
