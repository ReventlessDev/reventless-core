# Plan: GWT Harness — `Set` must respect `@subId`

**Status: done**

## Problem

`StateViewSlice_GWT.Make`'s in-memory `save` function ignores `subIdConfig` when `saveMode = Any`:

```rescript
// reventless-gwt/src/StateViewSlice_GWT.res  (current)
let save = (store, id, state, saveMode: QueryDb.saveMode, _ttl) =>
  switch (store->states(id), saveMode) {
  | (_, Any)          => store->setStates(id, [state])   // ← clobbers all sub-entries
  | ([], Init)        => store->setStates(id, [state])
  | ([_], Overwrite)  => store->setStates(id, [state])
  | _                 => Error(StaleState)->Promise.resolve
  }
```

`Set(pk, state)` calls `save(…, Any, None)`. In production, `save` extracts the sub-ID from the state via `subIdConfig.getSubId` and upserts only the matching (pk, subId) row — other rows under the same pk survive. In the GWT harness, `setStates(id, [state])` replaces the entire array, so the second `Set` under the same pk destroys the first.

### Symptom

Any StateViewSlice spec that uses `Set(pk, state)` on a table with `@subId` loses previously written sub-entries. For example, a timeline spec that `Set`s one row per timestamp will have each new event overwrite all prior rows under the same pk. Similarly, a spec that emits two `Set` actions with different sub-IDs in a single projection (e.g. a versioned entry + a `~current` sentinel) will only retain the last one.

## Fix

When `subIdConfig` is `Some`, `save` with `Any` mode should use `addState` (which already handles sub-ID correctly) instead of `setStates`:

```rescript
let save = (store, id, state, saveMode: QueryDb.saveMode, _ttl) =>
  switch (store->states(id), saveMode, Spec.subIdConfig) {
  | (_, Any, Some(_)) =>
    store->addState(id, state)
    Ok()->Promise.resolve
  | (_, Any, None)
  | ([], Init, _)
  | ([_], Overwrite, _) =>
    store->setStates(id, [state])
    Ok()->Promise.resolve
  | _ => Error(ReventlessInfra.QueryDb.StaleState)->Promise.resolve
  }
```

`addState` already extracts the sub-ID via `getSubId` and either updates an existing entry with the same sub-ID or appends a new one — exactly matching the production upsert behaviour.

### `Init` mode with sub-ID

`Create(pk, state)` calls `save(…, Init, None)`. The current harness allows Init only when `states == []`, which fails on the second Create under the same pk even when sub-IDs differ. Apply the same pattern:

```rescript
  | (_, Init, Some(_)) =>
    store->addState(id, state)  // addState won't overwrite an existing subId
    Ok()->Promise.resolve
```

## Verification

After the fix, any StateViewSlice GWT test that uses `Set` on a `@subId` table should be able to assert accumulation across multiple events or multiple sub-entries per projection. Downstream consumers with pinned tests can update their expectations to assert the correct (non-clobbered) behaviour.
