# Backlog: UpdateMultiState Stream-Based Update Function

**Origin:** Phase U from `docs/plans/stream-handler-implementation.md`

**Status:** Deferred — current implementation is sufficient; design challenges outweigh benefit

---

## Problem Statement

`UpdateMultiState` is the last place in `Projection.handleAction` where states are
materialized into an `array` before being passed to the user-supplied update function.
After Phase R, the load side already uses `loadStream->runCollect` internally. The
remaining materialization is the `array<state> => array<state>` function signature
in the public `action` variant type.

## Why Deferred

1. **Phase R already uses streams internally.** `handleAction` calls
   `loadStream(id)->Stream.runCollect` before handing the array to the update function.
   The only overhead is the final `runCollect` — which `applyChanges` needs anyway
   to compute a before/after diff (it requires both sets in memory simultaneously).

2. **Stream type parameters bleed into the public API.** Changing the variant to
   `UpdateMultiState('id, Stream.t<'state, 'e, 'r> => Stream.t<'state, 'e2, 'r2>)`
   forces error and requirement type variables into `Projection.action`, which
   complicates all consumers of the type.

3. **`applyChanges` materializes regardless.** The diff computation (added/changed/deleted
   sub-IDs) requires both `beforeStates` and `afterStates` as sets. A streaming update
   function would be collected immediately inside `applyChanges`, giving no real benefit.

4. **No current callers in the codebase produce `UpdateMultiState`.** Grep confirms it
   is only defined in `reventless-spec` and handled in `Projection.res`. Any change
   is a breaking API change for user code outside the repo.

## Possible Future Approaches

### Option A: Async update function
Change to `array<state> => promise<array<state>>`, allowing async work inside the
update function without full stream complexity. Less invasive than full streams.

### Option B: New `UpdateMultiStateStream` variant
Add a parallel variant alongside the existing one — no breaking change, users opt in
when they have a use case requiring streaming update semantics.

### Option C: Revisit if a concrete use case emerges
`UpdateMultiState` is rarely used. Wait until a real use case requires streaming
semantics before committing to a design.

## Preconditions to Revisit

- A concrete use case where `array => array` is insufficient (e.g., very large sub-item
  collections where lazy streaming during the update is necessary)
- A clear decision on how to handle stream type parameters in the `action` variant
