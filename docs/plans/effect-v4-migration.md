# Effect v4 Migration Plan

**Status:** Backlog — do NOT start until recommendation below is satisfied
**Created:** 2026-02-28
**Current version:** `effect ^3.17.0`
**Target version:** `effect@4` (stable release, not beta)

---

## Section 1: Situation Analysis

### 1.1 Beta status as of 2026-02-28

Effect v4 was announced on 2026-02-18. The current release is `4.0.0-beta.19`. Twenty beta
releases in ten days means the API surface is still changing daily:

- **beta.18** (two days ago): major STM refactor — `Effect.atomic` removed, `Effect.withTxState`
  added, new `TxDeferred`/`TxPriorityQueue`/`TxPubSub` modules
- **beta.19**: further STM stabilisation
- (hypothetical beta.20+): reverting `Config.withDefault` and `Effect.partition` behaviour back
  to v3

The v4 source lives in a separate `effect-smol` repository that will merge into the main repo at
RC stage. Migration codemods are promised but not yet released.

**v3 is feature-frozen** (bug fixes and security patches only) and remains the recommended choice
for production. The `latest` npm dist-tag still points to v3.

### 1.2 Breaking changes affecting existing bindings

The table below covers every `rescript-effect` binding module against v4 beta:

| Module | Impact | Specific changes |
|---|---|---|
| `Effect.res` | **High** | `fork` → `forkChild`; `catchAll` → `catch` (ReScript reserved word — needs `catch_`); `makeLatch` → `Latch.make` (new module); `makeSemaphore` → `Semaphore.make` (new module); `withPermits` likely moved to `Semaphore.withPermits` |
| `Cause.res` | **High** | `isEmpty`, `isFail`, `isDie`, `isInterrupted`, `parallel`, `sequential`, `failures`, `defects` all **removed** — replaced by a completely different flat-array model (`hasFails`, `hasDies`, `hasInterrupts`, `combine`, `reasons.filter(...)`) |
| `Latch.res` | **Medium** | Constructor `Effect.makeLatch` is gone; new constructor is `Latch.make` from the dedicated `Latch` module; `await_`/`open_`/`close` property shape needs verification |
| `Stm.res` | **Medium–High** | STM/TRef model refactored in beta.18 — `STM.commit` boundary model changed; verify `@scope("STM")` and `@scope("TRef")` still match v4 exports |
| `Exit.res` | **Low** | `toOption`, `causeOption` shape may shift slightly with the Cause restructure; constructors and predicates likely stable |
| `TestClock.res` / `TestContext.res` | **Unknown** | TestClock internally used FiberRef (now removed); `adjust` / `currentTimeMillis` JS-level names need verification |
| `Queue.res` | **Low** | No breaking changes documented; verify `InvalidPubSubCapacityException` removal doesn't affect Queue |
| `Ref.res` | **Low** | No changes documented |
| `SynchronizedRef.res` | **Low** | No changes documented |
| `Deferred.res` | **Low** | No longer an Effect subtype, but module function names (`make`, `await_`, `succeed`, `fail`, `completeWith`, `isDone`) appear stable |
| `Fiber.res` | **Low** | `join`, `interrupt`, `joinAll`, `collectAll` stable; `forkAll` was removed from Effect but not from Fiber |
| `Duration.res` | **Low** | `DurationInput` renamed to `Duration.Input` (TypeScript-level only, no JS change) |
| `Schedule.res` | **Low** | No renames documented; `jittered` now takes no arguments in v4 (previously accepted factor) |
| `PubSub.res` | **Low** | `InvalidPubSubCapacityException` removed but this does not affect the binding functions |

Beyond the bindings package, **consuming code in `reventless-in-memory` and
`reventless` also uses Effect functions directly:**

- `InMemory_Bus.res` uses `Effect.fork` (→ `forkChild`), `Effect.runFork` (verify),
  `Effect.forever`, `Queue.*`, `Deferred.*`
- `EventLog_Operations.res` uses `Schedule`, `Stm`, `Effect.retry`, `Effect.catchAll`
  (→ `catch_`)
- All tests in `reventless-in-memory/tests/` that import Effect via the bindings

---

## Section 2: Ordering Recommendation

### 2.1 Decision: Implement stream plans on v3 first, then migrate to v4 stable

**Recommended order:**

```
[NOW]  1. rescript-effect-binding-tests.md  — smoke tests against v3 (regression baseline)
       2. effect-stream-integration.md       — Phases A–E on v3 (production value now)
[WAIT] 3. effect-v4-migration.md            — after v4 reaches stable (this plan)
```

### 2.2 Why NOT to migrate to v4 beta now

**API churn is too high.** Twenty betas in ten days with breaking STM changes, Cause model
rewrites, and reverted behaviour. Each beta release could invalidate work just done.

**No codemods yet.** The Effect team promised codemods for the migration but they do not exist.
Migrating without codemods means manually auditing every external binding against the v4 source.

**Smoke tests don't exist yet.** Without the tests from `rescript-effect-binding-tests.md`, any
v4 migration is unguided — a broken binding produces a runtime crash, not a build error. Writing
the smoke tests *on v3 first* gives a complete regression baseline that pinpoints exactly which
bindings break when we bump the version.

**Stream APIs are low-churn between v3 and v4.** The `Stream` module function names (`fromIterable`,
`paginateEffect` / `paginateChunkEffect`, `runFold`, `runCollect`, etc.) are not in the v4
breaking-changes list. Implementing stream integration on v3 provides production value immediately
and will require only minor binding updates (if any) on v4.

**v3 is feature-frozen and stable.** Production code using v3 will continue to work. There is no
security or correctness reason to rush to v4 beta.

### 2.3 Why NOT to wait for v4 stable to implement the stream plans

The stream plans (B–E) replace array-based replay with lazy fold in `Aggregate_Callback` and
`StateChangeSlice_Callback` — a concrete memory and correctness improvement. These do not depend
on any v4-specific API. Waiting delays production value for no benefit.

### 2.4 When to start the v4 migration

Trigger: **v4 reaches Release Candidate** (RC tag on npm) — which will mean:
- API is stable (no more breaking changes between RC releases)
- Migration codemods are available
- All companion packages (`@effect/platform`, etc.) are at matching RC versions
- The `effect-smol` repo has merged back into the main `Effect-TS/effect` repo

Estimated timing: April–May 2026 (speculative, based on beta pace).

Do not start this migration on a beta. The smoke tests provide the signal: run
`npm install effect@4` in `rescript-effect`, run `npm test`, and read the failures.

---

## Section 3: Migration Steps

When the trigger above is met, execute phases in order. Each phase is a separate commit.

### Phase 0 — Preparation (prerequisite check)

Before touching any code:

1. Confirm `rescript-effect-binding-tests.md` is fully implemented and all tests pass on v3.
   The test suite is the migration safety net — it must exist before the upgrade.
2. Confirm all stream plan phases (A–E) are complete or explicitly deferred.
3. Pull the v4 migration guide and codemods:
   ```bash
   open https://github.com/Effect-TS/effect/blob/main/MIGRATION.md
   ```
4. Note the exact v4 stable version number for the upgrade.

### Phase 1 — Bump the version and run smoke tests

```bash
cd rescript/rescript-effect
npm install effect@4
npm run build      # expect compile errors in .res.mjs generated JS? No — ReScript compiles to JS
                   # first; runtime errors only surface at test time
npm test           # smoke tests identify every broken binding
```

Record which tests fail. These failures drive phases 2–6.

Build from monorepo root to catch downstream breakage in `reventless-in-memory`:
```bash
cd /path/to/root
npm run build 2>&1 | grep -E "Warning|warning|error|Error"
```

### Phase 2 — Fix `Effect.res` (high impact)

Changes needed based on v4 migration guide:

```rescript
// fork → forkChild
// Old:
@module("effect") @scope("Effect")
external fork: t<'a, 'e, 'r> => t<fiber<'a, 'e>, never, 'r> = "fork"

// New:
@module("effect") @scope("Effect")
external fork: t<'a, 'e, 'r> => t<fiber<'a, 'e>, never, 'r> = "forkChild"
// Keep external name 'fork' in ReScript — only the JS name changes

// catchAll → catch (JS name; ReScript external name stays catchAll to avoid reserved word)
// Old:
@module("effect") @scope("Effect")
external catchAll: (t<'a, 'e, 'r>, 'e => t<'a, 'e2, 'r2>) => t<'a, 'e2, 'r | 'r2> = "catchAll"

// New:
@module("effect") @scope("Effect")
external catchAll: (t<'a, 'e, 'r>, 'e => t<'a, 'e2, 'r2>) => t<'a, 'e2, 'r | 'r2> = "catch"
// ReScript binding name stays 'catchAll' — only the JS name changes to "catch"

// makeLatch — move binding to Latch.res (see Phase 3)
// Remove from Effect.res:
//   external makeLatch: bool => t<latch, never, never> = "makeLatch"
// Add to Latch.res:
//   @module("effect") @scope("Latch") external make: bool => t<Latch.t, never, never> = "make"

// makeSemaphore — move to new Semaphore.res
// Remove from Effect.res:
//   external makeSemaphore: int => t<semaphore, never, never> = "makeSemaphore"
// Add to new Semaphore.res

// withPermits — move to Semaphore.res
// Remove from Effect.res; re-bind as Semaphore.withPermits
```

After fixing `Effect.res`, rebuild and re-run smoke tests. Expect `EffectTest.res` to pass.

### Phase 3 — Rewrite `Cause.res` (high impact — complete API change)

The Cause module was fundamentally restructured. The new model is a flat list of "reasons"
instead of a recursive tree. Full rewrite required:

```rescript
// New Cause type: flat structure with reasons array
// cause.reasons: array of FailReason | DieReason | InterruptReason

// Removed and replacements:
//   isEmpty        → cause.reasons->Array.length == 0 (no binding, just ReScript code)
//   isFail         → hasFails
//   isDie          → hasDies
//   isInterrupted  → hasInterrupts
//   parallel       → combine (merges two causes; no longer distinguishes parallel vs sequential)
//   sequential     → combine (same as parallel in v4)
//   failures       → no direct replacement; use cause.reasons->Array.filter(Cause.isFailReason)
//   defects        → no direct replacement; use cause.reasons->Array.filter(Cause.isDieReason)
```

New `Cause.res` bindings to add:

```rescript
@module("effect") @scope("Cause")
external hasFails: t<'e> => bool = "hasFails"

@module("effect") @scope("Cause")
external hasDies: t<'e> => bool = "hasDies"

@module("effect") @scope("Cause")
external hasInterrupts: t<'e> => bool = "hasInterrupts"

@module("effect") @scope("Cause")
external combine: (t<'e>, t<'e>) => t<'e> = "combine"

@module("effect") @scope("Cause")
external isFailReason: 'reason => bool = "isFailReason"

@module("effect") @scope("Cause")
external isDieReason: 'reason => bool = "isDieReason"
```

Old bindings to either remove or keep as deprecated wrappers:
- `isEmpty`: remove — no direct v4 equivalent; callers use `cause.reasons.length === 0`
- `isFail`/`isDie`/`isInterrupted`: remove; add `hasFails`/`hasDies`/`hasInterrupts`
- `parallel`/`sequential`: remove; add `combine`
- `failures`/`defects`: remove; document migration path in comments

**Impact on `CauseTest.res`**: All tests that use the removed APIs must be rewritten using the
new model. Update `CauseTest.res` alongside `Cause.res`.

**Impact on `Stm.res`**: `STM.fail` produces a Cause — verify the downstream tests still make
sense with the new Cause structure.

### Phase 4 — Fix `Latch.res` and create `Semaphore.res`

**Latch.res**: Update constructor call site to use the new `Latch` module:

```rescript
// Old: Effect.makeLatch (in Effect.res)
// New: Latch.make (in Latch module)

// In Latch.res, update the make binding:
@module("effect") @scope("Latch")
external make: bool => t<t, never, never> = "make"

// Verify @get bindings for await_, open_, close still match the v4 Latch object shape
```

**Semaphore.res** (new file): The `makeSemaphore` + `withPermits` pair moves to a dedicated
module:

```rescript
// rescript/rescript-effect/src/Semaphore.res
type t

@module("effect") @scope("Semaphore")
external make: int => Effect.t<t, never, never> = "make"

@module("effect") @scope("Semaphore")
external withPermits: (t, int) => (Effect.t<'a, 'e, 'r> => Effect.t<'a, 'e, 'r>) = "withPermits"
```

Update any call sites that used `Effect.makeSemaphore` or `Effect.withPermits`.

### Phase 5 — Verify `Stm.res` (medium–high risk)

The STM/TRef transactional model was refactored in beta.18. Verification steps:

1. Check v4 exports: does `@scope("STM")` and `@scope("TRef")` still match the v4 module
   structure? (The `effect-smol` repo may have renamed the namespace.)
2. Run `StmTest.res` smoke tests — they exercise every TRef and STM binding.
3. If `STM.commit` boundary model changed (e.g., `Effect.transaction` replaces direct `commit`),
   update `Stm.res` and all call sites in `EventLog_Operations.res`.

### Phase 6 — Verify `TestClock.res` and `TestContext.res`

TestClock internally used `FiberRef` (now removed). The JS-level `TestClock.adjust` and
`TestClock.currentTimeMillis` may still work if the Effect team preserved the function names on
the TestClock object. Verification:

1. Run `TestClockTest.res` smoke tests.
2. If broken: check v4's test infrastructure exports and update the `@scope` or module path.

### Phase 7 — Verify remaining low-impact modules

Run their smoke tests and fix any discrepancies:

- `QueueTest.res` — verify `InvalidPubSubCapacityException` removal has no side effects
- `DeferredTest.res` — verify `Deferred` no longer being an Effect subtype doesn't affect bindings
- `FiberTest.res` — verify join/interrupt/joinAll/collectAll unchanged
- `RefTest.res`, `SynchronizedRefTest.res` — verify unchanged
- `PubSubTest.res` — verify unchanged
- `DurationTest.res` — verify constructor names unchanged
- `ScheduleTest.res` — verify `jittered` change (no-arg in v4); update binding if needed
- `ExitTest.res` — verify Cause restructure doesn't break Exit.causeOption

### Phase 8 — Update consuming code

After all bindings are fixed, update code in framework packages that uses them:

**`reventless/reventless-in-memory/src/adapter/InMemory_Bus.res`:**
- `Effect.fork` → ReScript `Effect.fork` still works (JS name changed to `forkChild`)
- `Effect.forever` — verify unchanged

**`reventless/reventless/src/components/EventLog_Operations.res`:**
- `Effect.catchAll` → ReScript `Effect.catchAll` still works (JS name changed to `catch`)
- `Stm.*` — update if STM model changed (Phase 5)

**`reventless/reventless-in-memory/tests/`:**
- All tests using Effect bindings — run the full test suite and fix any runtime failures

Build from root and run all tests:
```bash
npm run build && npm test
```

### Phase 9 — Update Stream.res (likely minor)

If the stream plans (A–E) were implemented on v3, verify `Stream.res` bindings against v4:

- `paginateEffect` (maps to JS `paginateChunkEffect`) — verify name unchanged in v4
- `fromIterable`, `fromEffect`, `fromQueue`, `map`, `filter`, `take`, `runFold`,
  `runCollect`, `runHead`, `runForEach`, `mapEffect`, `fromReadableStream` — verify all unchanged
- Update `StreamTest.res` if any binding names changed

---

## Section 4: File Inventory

Files that will change in this migration:

| File | Phase | Change type |
|---|---|---|
| `rescript/rescript-effect/package.json` | 1 | `"effect": "^4.x.x"` |
| `rescript/rescript-effect/src/Effect.res` | 2 | `fork` JS name, `catchAll` JS name, remove `makeLatch`/`makeSemaphore`/`withPermits` |
| `rescript/rescript-effect/src/Cause.res` | 3 | Full rewrite |
| `rescript/rescript-effect/src/Latch.res` | 4 | Update constructor binding |
| `rescript/rescript-effect/src/Semaphore.res` | 4 | New file |
| `rescript/rescript-effect/src/Stm.res` | 5 | Possibly update if STM model changed |
| `rescript/rescript-effect/src/TestClock.res` | 6 | Possibly update if FiberRef removal broke it |
| `rescript/rescript-effect/src/TestContext.res` | 6 | Possibly update |
| `rescript/rescript-effect/src/Schedule.res` | 7 | `jittered` signature if changed |
| `rescript/rescript-effect/src/Exit.res` | 7 | `causeOption` if Cause restructure impacts it |
| `rescript/rescript-effect/tests/CauseTest.res` | 3 | Rewrite tests for new Cause model |
| `rescript/rescript-effect/tests/EffectTest.res` | 2 | Update `catchAll`/`fork` tests |
| `rescript/rescript-effect/tests/LatchTest.res` | 4 | Update constructor test |
| `rescript/rescript-effect/tests/StmTest.res` | 5 | Update if STM changed |
| `rescript/rescript-effect/tests/ScheduleTest.res` | 7 | Update `jittered` test |
| `reventless/reventless-in-memory/src/adapter/InMemory_Bus.res` | 8 | Verify at runtime |
| `reventless/reventless/src/components/EventLog_Operations.res` | 8 | Verify at runtime |
| `rescript/rescript-effect/src/Stream.res` | 9 | Verify stream binding names |
| `rescript/rescript-effect/tests/StreamTest.res` | 9 | Verify stream tests |

---

## Section 5: Known Risks and Constraints

### `catchAll` → `catch` — ReScript reserved word

In v4, the JS function name is `catch`. This is a reserved word in ReScript. The binding in
`Effect.res` must use a different ReScript name:

```rescript
// Option A: Keep the ReScript name catchAll, change only the JS string
external catchAll: ... = "catch"

// Option B: Rename to catch_ (underscore suffix convention)
external catch_: ... = "catch"
```

Option A (keep `catchAll`) is the least disruptive — all call sites continue to work unchanged.
Option B requires renaming every call site but is more honest about the underlying name change.
**Recommendation: Option A** for the migration; Option B can be a follow-up refactor.

### `Cause.failures` / `Cause.defects` have no direct replacement

In v3, `Cause.failures` returned `Chunk<E>` (array of typed errors). In v4, you filter
`cause.reasons` with `Cause.isFailReason`. The `failureOption`, `failureOrCause`, and
`failureMaybe` helpers may or may not exist in v4. Check at migration time and implement
ReScript-level helpers if needed.

### STM uncertainty

The STM refactor in beta.18 is the highest-risk unknown. If the `STM` namespace or `TRef` API
changed substantially, `EventLog_Operations.res` may need a significant rewrite. Evaluate after
running `StmTest.res` on v4.

### `Schedule.jittered` argument change

In v3: `Schedule.jittered(~min=0.8, ~max=1.2)` (optional factor parameters).
In v4: `Schedule.jittered` is a value (no arguments), always uses 80%–120% range.
The current binding in `Schedule.res` must be updated to a value binding (not a function).

### Companion packages

If any of the Reventless framework packages depend on `@effect/platform` or other companion
packages, those must also be upgraded to the matching `4.x.x` version simultaneously.
Currently the `rescript-effect` package only depends on `effect` itself — no companion packages.

---

## Section 6: Acceptance Criteria

The migration is complete when:

1. `rescript/rescript-effect/package.json` has `"effect": "^4.x.x"`
2. `npm run build` in `rescript/rescript-effect` produces zero warnings
3. All smoke tests in `rescript/rescript-effect/tests/` pass on v4
4. `npm run build` from monorepo root produces zero warnings
5. All tests in `reventless/reventless-in-memory/` pass unchanged
6. All tests in `reventless/reventless/` pass unchanged
7. The `Semaphore.res` module exists and is included in `rescript.json`

---

## Section 7: Future Watch Items

Monitor the v4 release notes for:

- **v4 RC announcement** — the migration trigger
- **Codemods release** — will automate some of the renaming
- **`effect-smol` → `Effect-TS/effect` merge** — confirms API freeze
- **Schedule.jittered** — confirm no-arg form is final
- **Stream module** — confirm `paginateChunkEffect` name unchanged
- **TestClock** — confirm FiberRef removal didn't break the adjust/currentTimeMillis API
