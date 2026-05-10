# Plan: Remove Dead `Error` Branches in `Aggregate_Callback`

**Analysis**: [aggregate-command-handling-review.md](../../analysis/aggregate-command-handling-review.md) — Correctness §"Dead code in the reduce accumulator"

## Problem

Two branches in [`Aggregate_Callback.res`](../../reventless/reventless-core/src/components/Aggregate/Aggregate_Callback.res) are unreachable today:

### Branch 1 — `processCommand`'s `Error(_)` arm ([L72](../../reventless/reventless-core/src/components/Aggregate/Aggregate_Callback.res#L72))

```rescript
let processCommand = (acc, command') =>
  switch acc {
  | Ok((state, events)) =>
    ...
    Ok((newState, ...))
  | Error(_) as error => Effect.succeed(error)  // ← unreachable
  }
```

`processCommand` always returns `Ok(...)` (even on decide errors — see the sibling plan [aggregate-propagate-decide-errors.md](aggregate-propagate-decide-errors.md)), so the reduce accumulator is never `Error(_)`. The branch is dead.

### Branch 2 — `replayProcessAppend`'s `JsError.throwWithMessage` ([L107](../../reventless/reventless-core/src/components/Aggregate/Aggregate_Callback.res#L107))

```rescript
let events = switch result {
| Ok((_, generatedEventsWithMeta)) => ...
| Error(error) => JsError.throwWithMessage(error)  // ← unreachable, also catastrophic
}
```

Same root cause: `result` is always `Ok` because `processCommand` only emits `Ok`. If it ever fired, `JsError.throwWithMessage` inside an `Effect.flatMap` would crash the entire group's processing — taking out all commands for that aggregate, not just the offending one.

## Goals

- Remove both branches.
- Make the type system reflect what the runtime actually does: `processCommand` returns `Effect.t<(state, eventsAndMeta)>`, no outer `result`.
- Eliminate the latent landmine of `JsError.throwWithMessage` inside an Effect.

## Non-goals

- Re-introducing real rejection. That's the work of [aggregate-propagate-decide-errors.md](aggregate-propagate-decide-errors.md), which establishes a *typed* rejection path. Doing both at once is fine; this plan can also ship standalone as a tidy-up.
- Behavioural change. The dead code is dead — removing it is a no-op runtime-wise.

## Approach

If shipping standalone (no rejection plumbing): drop the `result` wrapper from `processCommand`'s accumulator entirely.

```rescript
// Before:
let processCommand = (acc, command') =>
  switch acc {
  | Ok((state, events)) => ... Effect.succeed(Ok((newState, ...)))
  | Error(_) as error => Effect.succeed(error)
  }

// After:
let processCommand = ((state, events), command') =>
  ...
  Effect.succeed((newState, Array.concat(events, [(...)])))
```

The reduce starts from `Effect.succeed((Behavior.initialState, []))` and threads the tuple. The `match result` block in `replayProcessAppend` collapses to direct destructuring — no `Error` arm, no throw.

If shipping **after** [aggregate-propagate-decide-errors.md](aggregate-propagate-decide-errors.md): the per-command outcome lives inside the events list as `cmdOutcome`; the outer accumulator is still `(state, outcomes)` with no `result` wrapper. Same simplification.

## Steps

### Step 1 — Coordinate with the rejection-propagation plan

If [aggregate-propagate-decide-errors.md](aggregate-propagate-decide-errors.md) is being implemented in the same PR, fold this into it. Otherwise:

### Step 2 — Drop the `result` wrapper

In [`Aggregate_Callback.res`](../../reventless/reventless-core/src/components/Aggregate/Aggregate_Callback.res):

- `processCommand` accumulator: `(state, events)` directly.
- Reduce: `Array.reduce(Effect.succeed((Behavior.initialState, [])), ...)`.
- `replayProcessAppend`: destructure the tuple directly; remove the `Error` arm and the `JsError.throwWithMessage` call.

### Step 3 — Tests

Existing tests should continue to pass unchanged — the dead branches were dead. Confirm:

- All `tests/components/Aggregate/Aggregate_CallbackTest.res` cases pass.
- All `examples/online-shop-aggregates/*` GWT tests pass.
- No new test additions required (the change is a refactor of unreachable code).

### Step 4 — Build verification

Per `.claude/rules/conventions.md`, run zero-warning verification:

```bash
pnpm run build 2>&1 | grep -E "Warning|warning|error|Error"
```

Should be clean.

### Step 5 — Document

Move plan to `done/`. Update the analysis caveat to mark resolved.

## Open questions

- **Is there a future world where `processCommand` legitimately needs to fail-fast?** Possibly — e.g. a fatal infrastructure error mid-batch. Today no such case exists; if one arises, the right response is a typed effect failure (`Effect.fail`), not a `result` accumulator. The current shape is the worst of both: typed result that's never used. Drop it; reintroduce real failure handling only when there's a real failure to handle.

## Status

Not started. Trivial; ship opportunistically.
