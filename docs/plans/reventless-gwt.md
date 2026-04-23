# Reventless GWT — Test Framework, DSLs, Runner

## Status: BACKLOG

## Goal

Build a single Reventless-owned package `@reventlessdev/reventless-gwt` that ships:

- Given-When-Then DSLs for **every** Event Modeling slice type (Aggregate, ReadModel, all five DCB slices, cross-pattern automation, read-model query patterns).
- A runner-agnostic `Outcome.outcome` algebra that decouples assertion logic from any test runner.
- A standalone CLI runner (`reventless-gwt`) with five output formats: human, JSON, TAP, JUnit, VS Code Test API.
- An optional Jest binding so existing test infrastructure continues to work during migration.

End state: every GWT file in the monorepo runs through `reventless-gwt run`, the AI loop consumes the same CLI with `--format=json`, the IDE consumes it with `--format=vscode`, and Jest is no longer mandatory for slice testing.

See [`docs/analysis/given-when-then-specifications.md`](../../analysis/given-when-then-specifications.md) for the design rationale, alternatives considered, and detailed format specifications.

---

## Why this matters

1. **DCB slices have no test DSL today** — every DCB test in the monorepo hand-rolls `expect(decide(...))->toEqual(...)` against records constructed by the test author. Half the framework is invisible to any AI generation loop.
2. **The three existing DSLs** (`BehaviorTest`, `EventMappingTest`, `ProjectionTest`) are inconsistent in shape, duplicated in `reventless-in-memory/src/test/`, and only one (`ProjectionTest`) is actually concurrency-safe.
3. **Jest output is JS-shaped** — every variant failure shows `{TAG: "X", _0: ...}` instead of `X({...})`, costing every test author cognitive overhead on every failure.
4. **The AI loop has no structured failure data** — parsing Jest stdout works for trivial cases but breaks down on slices with multiple assertions per test.

The Outcome algebra plus the Reventless-owned runner solves all four with one architectural move.

---

## Phased migration

Each stage is one PR. Deprecation aliases keep every PR green.

### Stage 1 — Create `reventless-gwt`, consolidate existing DSLs

**Status:** Complete — commit `4c2895bd` on `alpha`.

**Goal:** Single package home for every existing DSL. Delete the `reventless-in-memory/src/test/*` duplicates.

**Actions taken:**

1. Created `reventless/reventless-gwt/` package with `package.json`, `rescript.json`, `bin/reventless-gwt.mjs` stub (namespace `ReventlessGwt`, deps on `rescript-effect`, `reventless-spec`, `reventless-infra`, `reventless-core`).
2. `git mv` from `reventless-core/tests/` into `reventless-gwt/src/`:
   - `BehaviorTest.res` → `Behavior_GWT.res`
   - `EventMappingTest.res` → `EventMapping_GWT.res`
   - `ProjectionTest.res` → `Projection_GWT.res`
   - `TestFixtures.res` → `TestFixtures.res` (added mid-stage — only used by the GWT DSLs and downstream tests once the plugin tests moved out of reventless-core).
   New file `reventless-gwt/src/AsyncTest.res` as a content copy. `reventless-core/tests/AsyncTest.res` was kept as an internal Jest-binding helper to avoid a `reventless-core` ↔ `reventless-gwt` dependency cycle (13 reventless-core unit/integration test files `open AsyncTest`).
3. Deleted the three duplicates in `reventless-in-memory/src/test/`. `Mocks/` and `TestRunner.res` remain; `rescript.json` unchanged.
4. Declared `@reventlessdev/reventless-gwt` as a **devDependency** of `reventless-in-memory` and of the six example plugin packages (not runtime — stays out of the AWS Lambda layer). Also added to root `rescript.json` and root `package.json` so the monorepo build picks it up.
5. Relocated three framework-internal Plugin GWT tests (+ `PluginFixtures.res`) from `reventless-core/tests/plugin/` to `reventless-in-memory/tests/plugin/` — reventless-core itself can't depend on reventless-gwt without a cycle, and reventless-in-memory already depends on both. Agreed long-term home (reventless-gwt's `tests/` dir is reserved for per-DSL worked examples in later stages).
6. Codemodded 24 consumer files:
   - `ReventlessInMemory.BehaviorTest` → `ReventlessGwt.Behavior_GWT`
   - `ReventlessInMemory.ProjectionTest` → `ReventlessGwt.Projection_GWT`
   - `ReventlessInMemory.AsyncTest` → `ReventlessGwt.AsyncTest`
   - In-memory internal tests: `open AsyncTest` → `open ReventlessGwt.AsyncTest` (and `.Expect`)
   - Relocated plugin tests switched `TestFixtures.*` → `ReventlessGwt.TestFixtures.*` to avoid a warning-44 shadow against the in-memory `TestFixtures.res`.
7. Refined `Behavior_GWT.Make`'s signature to take an inline `BehaviorSpec` module type (matching the former in-memory pattern). Rationale discovered during Stage 3 probing (see Stage 3's Deviations): `Behavior.T`'s inner `Spec` in reventless-spec only declares the `@schema` types — no `name` field — so the GWT layer needs a richer second parameter to thread `Spec.name` into failure hints. The original Stage 1 commit blamed a "cross-package 'not included in' compiler error" but that was misdiagnosed: it doesn't reproduce today (a probe with `(Spec: Reventless.StateChangeSlice.Spec) => ...` compiles cleanly).
8. Removed obsolete `testPathIgnorePatterns` entries for the three moved DSL files in `jest.config.js` and `reventless-core/package.json`. `AsyncTest.res.mjs` entries kept (the file is still there as an internal helper).

**Deviations from the original plan:**

- **Deprecation aliases skipped.** Step 6's codemod updated every in-repo consumer in the same PR, leaving no remaining internal references to the old paths. Any external consumer of the old `ReventlessInMemory.BehaviorTest`/`ProjectionTest`/`AsyncTest` exports gets a hard compile error rather than a warning — faster feedback, cleaner tree, and removes the Stage D cleanup step.
- **`AsyncTest.res` kept in `reventless-core/tests/`** (Option 1 of two cycle-break alternatives) instead of moved. Contents identical to the reventless-gwt copy; both are trivial Jest `@val external` bindings.
- **`TestFixtures.res` moved to reventless-gwt** (not covered by the original plan step 2). Surfaced only after the plugin tests moved — at that point reventless-core had zero remaining consumers of the file.
- **Plugin GWT tests relocated to reventless-in-memory** rather than left in reventless-core or rewritten — the original plan did not address these framework-internal GWT tests.

**Acceptance:**

- ✅ All existing tests pass with the new import paths (116 suites / 1069 tests).
- ✅ No GWT DSL files under `reventless-in-memory/src/test/` other than `TestRunner.res` and `Mocks/`.
- ✅ Zero new compiler warnings.
- ⚠️ Deprecation aliases skipped (see deviation above) — old paths fail-fast instead.

### Stage 2 — `Outcome` algebra + `JestBind` adapter

**Status:** Complete

**Goal:** Refactor every `then*` combinator to return `Outcome.outcome` instead of `Jest.assertion`. Existing test files compile unchanged.

**Actions taken:**

1. Added `reventless-gwt/src/Outcome.res` with the eight `mismatch` variants from analysis §3.2 (`EventsMismatch`, `ErrorMismatch`, `StateMismatch`, `NoEventExpected`, `TodoMismatch`, `TranslateError`, `QueryRowsMismatch`, `Throw`), `type outcome = result<unit, mismatch>`, plus `format` (human-readable) and `toJson` (closed-schema kind-discriminated payload per §3.3). `AppendConditionMismatch` deferred to Stage 4 as planned.
2. Added `reventless-gwt/src/Hint.res` exporting `type t = {locus, branch, message}` and `forMismatch(~slice=?, mismatch)` with the locus table from §3.2; plus `toJson` and `format` helpers.
3. Refactored each DSL's `then*` combinators to construct `Outcome.mismatch` instead of calling `Jest.fail`:
   - `Behavior_GWT` — every `then*` now returns `Outcome.outcome` (sync). `test` signature is `(string, unit => Outcome.outcome) => unit`. Uses `Message.encode(eventSchema | errorSchema)` to build JSON payloads.
   - `Projection_GWT` — every `then*` now returns `promise<Outcome.outcome>`. Replaced the `Jest.Expect.plainPartial<unit => promise<store>>` shim with a plain `storeThunk = unit => promise<store>`. `thenThrow`/`thenFail` switched from `toThrow` to catching inside the thunk.
   - `EventMapping_GWT` — every `then*` now returns `promise<Outcome.outcome>`. Source/target errors and target-event mismatches map to `ErrorMismatch`/`EventsMismatch` respectively.
4. Added `reventless-gwt/src/JestBind.res` — exposes `describe`, `test`, `testPromise` that convert `Outcome.outcome` → `Jest.assertion` via `Jest.pass` / `Jest.fail(format(m) ++ format(hint))`.
5. Each DSL's `describe`/`test` exports now delegate to `JestBind`. Test files compile unchanged — only the test body's inferred return type flows through (was `Jest.assertion`, now `Outcome.outcome` / `promise<Outcome.outcome>`).

**Deviations from the original plan:**

- **`ErrorMismatch` gained an `actualEvents: array<JSON.t>` field** (beyond the §3.2 sketch). Needed by `thenError` when `decide` returned `Ok([events])` instead of `Error` — the JSON payload in §3.3 already includes `actualEvents`, so this aligns the construction-time type with the serialised shape.
- **`StateMismatch.expected` is `option<JSON.t>`** (not `JSON.t`). Lets `thenNoState` express "expected nothing, got state" uniformly.
- **Source-location file+line hint** (filename + line number captured at `then*` call time) is not yet populated. The `Hint` module provides the `kind → {locus, branch, message}` mapping from §3.2; the stack-frame capture is deferred to Stage 7 where the runner needs it for the human/JSON/VS Code formatters.
- **`Projection_GWT`'s `plainPartial` shim was dropped.** The `expect(async () => ...)` wrapping existed only to satisfy `toThrow` semantics. Replaced with a plain `storeThunk = unit => promise<store>`; `thenThrow`/`thenFail` now catch exceptions inside the thunk directly. Consumer test files were unaffected (they never annotated the intermediate type).

**Acceptance:**

- ✅ Every existing test file compiles and passes unchanged (116 suites / 1069 tests).
- ✅ `Outcome.format(mismatch)` produces a human-readable string.
- ✅ `Outcome.toJson(mismatch)` produces a closed-schema JSON payload per §3.3.
- ⚠️ File+line source-location hint deferred to Stage 7 (see deviation above).

### Stage 3 — DCB DSLs (5 modules)

**Status:** Complete

**Goal:** Stop hand-rolling DCB tests. Same vocabulary as Aggregate DSLs.

**Actions taken:**

1. `StateChangeSlice_GWT.res` — `Make(Spec)` runs `evolve` over given consumed events, calls `decide`. Combinators: `givenEvents`/`whenCmd`/`thenEvent`/`thenEvents`/`thenNoEvent`/`thenError`/`thenEventWithError`/`thenEventsWithError`. Uses an inline `SliceSpec` module type (mirroring `Behavior_GWT`) so sury-ppx processes `@schema` attributes in the same compilation unit.
2. `StateViewSlice_GWT.res` — `Make(Spec)`. Reuses `Projection.handleActions` against an in-memory dict store (lift-and-simplify of `Projection_GWT`'s store: no `Message.event'` envelope, no `sourceName`/`subIdConfig` indirection via `Projection.Mapping`). Combinators mirror `Projection_GWT`: `givenEvents`/`whenEvent(s)`/`thenState(sWithId)`/`thenAllStates`/`thenNoState`/`thenThrow`/`thenFail`.
3. `AutomationSlice_GWT.res` — `Make(Spec)`. Unit combinators: `givenEvent→whenCollect→thenTodos`, `givenEvent→whenResolve→thenResolved`, `givenTodo→whenProcess→thenCommand`/`thenNoCommand`. Scenario combinators: `givenEvents→whenSweep→thenCommands→andThenEvents→thenScenarioTodos`.
4. `InboundTranslationSlice_GWT.res` — `Make(Spec)`. No `given` clause. Combinators: `whenInput→thenCommand(s)`/`thenNoCommand`/`thenTranslateError`.
5. `OutboundTranslationSlice_GWT.res` — `Make(Spec)`. Unit-collect: `givenEvent→whenCollect→thenTodos`. Translate pipeline: `givenTodo→whenTranslateMocked(mockFn)→thenCommand`/`thenNoCommand`/`thenRetryRecorded`/`thenTodoStatus`. The mock function replaces `Spec.translate` to avoid external service calls; retry semantics are asserted via `thenRetryRecorded(n)` (Error result) and `thenTodoStatus("id", #Pending|#Completed)`.
6. Per-DSL worked-example tests ship in `reventless-gwt/tests/` (5 files, 13 tests) exercising happy and error paths. `tests/` registered as a `dev`-typed source in `rescript.json`. Added `test` script + Jest config to `reventless-gwt/package.json` and a `reventless-gwt` project entry to root `jest.config.js` so `pnpm test` at the monorepo root picks them up.

**Deviations from the original plan:**

- **`StateChangeSlice_GWT` does not yet auto-derive the append condition.** That's Stage 4's work (`thenAppendsConditionedOn`) and is gated on the `AppendConditionMismatch` variant. Current implementation exercises only `evolve` + `decide`, not the DCB tag query — enough for pure decide-level tests.
- **`AutomationSlice_GWT.thenCommand/thenCommands` use `EventsMismatch`** (not a new `CommandsMismatch` variant). Commands are encoded as `{id, command}` JSON pairs into the existing `EventsMismatch` payload — keeps the Outcome algebra closed at §3.2's eight variants.
- **`OutboundTranslationSlice_GWT.thenRetryRecorded(n)`** asserts the translate result was `Error(_)` but does not track a retry counter — the slice runtime owns retry state externally. The `n` argument documents intent only. When Stage 7 introduces the runner with richer scenario state, this can tighten.
- **`OutboundTranslationSlice_GWT`'s spec omits `translate`**. `whenTranslateMocked` always supplies the translate function from the test — the spec only needs `collect` + `consumedEvent`/`outboundItem`/`inboundCommand` schemas for the DSL to type-check. The spec's own `translate` is unit-tested elsewhere (component callback tests).
- **Slice-name threading added after initial Stage 3 landing.** Each DSL's inline `SliceSpec` gained `let name: string` (plus `Projection_GWT` uses `Projection.sourceName` and `EventMapping_GWT` uses `${Source.name}→${Target.name}`). `JestBind.test`/`testPromise`/`toAssertion` grew an optional `~slice=?` forwarded to `Hint.forMismatch`, so failure messages now read `Look at AddCategory.decide` instead of the `<slice>` fallback. Worked-example fixtures updated accordingly (one extra line per stub).
- **Destructive substitution (`:=`) in `Behavior_GWT`/`EventMapping_GWT` replaced with non-destructive (`=`)** for readability. The dual-parameter shape itself is retained — see Stage 1 step 7's updated rationale. A probe confirmed `Reventless.StateChangeSlice.Spec` and `Reventless.Behavior.T` can be referenced cross-package without the "not included in" error the Stage 1 note blamed; the real reason for the inline specs is that `Behavior.T`'s inner Spec lacks `name` and ReScript's `with module` can't add it.

**Acceptance:**

- ✅ All five DSLs return `Outcome.outcome` (Stage 2 algebra).
- ✅ Combinators match the API examples in `docs/analysis/given-when-then-specifications.md` §4.2–4.6 (with the deviations above).
- ✅ One worked example test per DSL ships in `reventless-gwt/tests/` — 5 test files, 13 tests, all passing.
- ✅ Full monorepo test suite: 121 suites / 1082 tests (up from 116 / 1069 in Stage 2) — zero regressions.
- ⚠️ Auto-derived append condition deferred to Stage 4 (see deviation above).

### Stage 4 — `thenAppendsConditionedOn` for `StateChangeSlice_GWT`

**Status:** Not started

**Goal:** Make the DCB optimistic-concurrency contract specifiable. Default mode auto-derives the expected condition; explicit mode documents it.

**Actions:**

1. Add `Outcome.AppendConditionMismatch` variant.
2. Inside `StateChangeSlice_GWT.Make`, compute the expected append condition via `Reventless.DcbTag.buildQueryFromCommand` + `Reventless.DcbTag.extractVariantNames` (same helpers the runtime uses).
3. Every `whenCmd` internally asserts the auto-derived condition matches what the slice's runtime would build.
4. Expose `thenAppendsConditionedOn([...])` for explicit-equality documentation mode.
5. Expose `thenAppendsConditionedOnExactly([...])` for strict-only mode (skips auto-derivation).

**Acceptance:**

- Forgetting a `@s.matches(DcbTag.string)` annotation on a command field fails the test with `AppendConditionMismatch`.
- Explicit `thenAppendsConditionedOn` matches the auto-derived condition (two-way equality).

### Stage 5 — `Mapping_GWT` (cross-pattern automation)

**Status:** Not started

**Goal:** Generalise `EventMapping_GWT` so source and target can each be Behavior or StateChangeSlice.

**Actions:**

1. Define a small `Source.T`/`Target.T` module type abstracting Behavior + StateChangeSlice (`name`, `decide`, `evolve`, `initialState`, `event`, `consumedEvent`).
2. `Mapping_GWT.Make(Source, Target, Mapping)` accepts both kinds for both positions.
3. Implement the four producer/consumer combinations from [`event-source-connection-matrix.md`](../../analysis/event-source-connection-matrix.md).
4. Finish the error combinators that were commented out in the old `EventMappingTest`: `thenTargetError`, `thenTargetEventsWithError`.

**Acceptance:**

- One worked example for each combination (`Aggr→Aggr`, `Aggr→DCB`, `DCB→Aggr`, `DCB→DCB`).
- `EventMapping_GWT` becomes a thin alias over `Mapping_GWT` with `Aggr→Aggr` specialisation, kept for migration backward-compat.

### Stage 6 — `Query_GWT` (read model query patterns)

**Status:** Not started

**Goal:** Make read model index/resolver/subId design specifiable.

**Actions:**

1. Add `Outcome.QueryRowsMismatch` variant.
2. `Query_GWT.Make(Spec: ReadModel.Spec)` provides:
   - `givenStore([(id, state), ...])` — populate the in-memory store
   - `givenStore_for(Spec, [...])->andStore_for(Spec, [...])` — multi-store for resolvers
   - `whenQueryById(id)`, `whenQueryByCompositeId({id, subId})`
   - `whenQuery({by, value, index?, filter?, limit?})`
   - `whenResolve({from, id, field})`, `whenResolveMany`
   - `thenRow`, `thenRows`, `thenRowCount`, `thenResolved`
3. Each scenario type pins down a specific `ReadModel.config` requirement (per the table in §4.8 of the analysis).
4. Implement the in-memory query runner (similar to `Projection_GWT`'s store) honouring `subIdConfig`, indexes, filters, limits.

**Acceptance:**

- Querying a store without the required index produces a clear `QueryRowsMismatch` with the missing-index hint.
- Composite-key tests pass when `subIdConfig` is set correctly, fail with structured mismatch when not.
- Resolver tests pass when `idResolvers`/`idsResolvers` entries match the cross-table reference; fail with structured mismatch when not.

### Stage 7 — CLI runner

**Status:** Not started

**Goal:** Replace Jest as the default GWT runner. Single CLI with five output formats.

**Actions:**

1. **Public modules:** `Bind.res` (CLI-bound `describe`/`test` that pushes outcomes to `Collector`), `Filter.res` (`only`/`skip`/`xtest`).
2. **CLI internals:**
   - `Cli.res` — argv parsing for `run` / `discover` / `watch` subcommands and all flags.
   - `Discovery.res` — file walker for `*_GWT.res.mjs`, respects `.gitignore`.
   - `Loader.res` — `await import(url)` per test file.
   - `Collector.res` — module-level array drained per file.
   - `RenderRescript.res` — sury-aware ReScript-syntax value renderer.
   - `Diff.res` — schema-aware structural diff producing `fieldDiff`.
   - `Watch.res` — chokidar-based file watcher.
   - `Cancellation.res` — SIGINT trap, clean shutdown.
3. **Formatters:**
   - `formatters/Human.res` — terminal-coloured (~150 lines).
   - `formatters/Json.res` — structured envelope + NDJSON streaming, schemaVersion field.
   - `formatters/Tap.res` — TAP 14 with YAML diagnostics, subtests for `describe`.
   - `formatters/Junit.res` — XML wrapper.
   - `formatters/VsCode.res` — NDJSON event stream with `discover` mode.
4. **Bin entry:** `bin/reventless-gwt.mjs` (~30 lines) calling into the compiled core.
5. Add `chokidar` and `picocolors` as runtime deps.

**Acceptance:**

- `pnpm exec reventless-gwt run` runs every `*_GWT.res.mjs` under `tests/` and exits 0/1 correctly.
- `--format=human` shows ReScript-syntax expected/actual + locus hint.
- `--format=json` matches the schema documented in §3.3 of the analysis (versioned via `schemaVersion`).
- `--format=tap` produces valid TAP 14 with YAML diagnostics, consumable by `tap-spec`.
- `--format=vscode` discovery mode lists all tests without execution; run mode emits per-test lifecycle events.
- Watch mode re-runs only affected files on change.
- SIGINT marks in-flight tests as `skipped{reason: "cancelled"}`, emits `runEnd`, exits cleanly.
- Self-tests in `reventless-gwt/tests/` use the runner to test itself (constructed `Outcome` values fed through formatters and asserted).

### Stage 8 — `reventless-vscode` extension

**Status:** Not started

**Goal:** VS Code Test panel integration via the `--format=vscode` runner mode.

**Actions:**

1. New `reventless-vscode/` package (separate npm publishable, marketplace target — placement TBD, possibly `packages/reventless-vscode/` since it's tooling).
2. ~80 lines of TypeScript per the example in §3.3 of the analysis:
   - Discovery: spawn `reventless-gwt discover --format=vscode`, populate `TestController` items.
   - Run handler: spawn `reventless-gwt run --format=vscode --filter=<id>`, forward NDJSON events to `TestRun` API.
   - Continuous Run: spawn with `--watch`, restart per file change.
   - Cancellation: forward `CancellationToken` to SIGINT.
3. Marketplace publishing config.

**Acceptance:**

- Test tree populates on workspace open.
- Run/Run-with-debug from the test panel triggers the CLI and reports results.
- Failure messages show ReScript-syntax expected/actual in VS Code's diff view.
- Cmd+Click on a failure jumps to the implementation file (`hint.locus`), not the test file.

### Stage 9 — `@@reventless.gwt` PPX

**Status:** Not started

**Goal:** Eliminate the two `include` lines at the top of every GWT file. Same convention layer as `@@reventless.spec` / `@@reventless.behavior`.

**Actions:**

1. Add a new file-level annotation `@@reventless.gwt` recognised by `reventless-ppx`.
2. PPX inspects the folder name (`Aggregate/`, `StateChangeSlice/`, `StateViewSlice/`, etc.) and the file name to derive the slice kind.
3. Auto-injects `include ReventlessGwt.<Kind>_GWT.Make(<Spec>, [<Behavior>?])` and `include ReventlessGwt.Bind` (or `JestBind` based on a project-level config).
4. Update the macOS + Linux PPX binaries (per MEMORY: Docker rebuild required for Linux).

**Acceptance:**

- A test file with only `@@reventless.gwt` plus the actual `describe`/`test` calls compiles and runs.
- The PPX picks up the right DSL kind from folder name without explicit configuration.

### Stage 10 — Documentation

**Status:** Not started

**Goal:** A single canonical guide for GWT testing in Reventless.

**Actions:**

1. New `docs/guides/given-when-then.md`:
   - The four-slice / four-vocabulary table (matches §1 of the analysis).
   - One fully-worked example per slice type (10 examples).
   - Output format reference.
   - Migration tips for existing tests.
2. Cross-link from `docs/guides/component-testing-guide.md`.
3. Update `docs/analysis/given-when-then-specifications.md` status note: "Implemented as of v…".
4. Update `CLAUDE.md` PPX section if Stage 9 lands.

**Acceptance:**

- A new contributor reading `docs/guides/given-when-then.md` can write a working `_GWT.res` for any slice type without consulting the analysis.

---

## Migration of existing tests

Independent track that runs alongside the staged work above.

### A. Aggregate Behavior + ReadModel Projection — codemod (after Stage 1)

Mechanical:

```
- include ReventlessInMemory.BehaviorTest.Make(Category, CategoryBehavior)
+ include ReventlessGwt.Behavior_GWT.Make(Category, CategoryBehavior)
+ include ReventlessGwt.Bind                 // or JestBind during transition
```

Plus optional file rename: `*BehaviorTest.res` → `*Behavior_GWT.res`.

If Stage 2's harmonisation drops `plainPartial` for synchronous chains, the projection codemod also rewrites `whenEvent(...)->thenState(...)` from the deferred form to a direct value chain.

### B. DCB hand-rolled tests — semi-automatic LLM rewrite (after Stage 3)

The current `*DecisionTest.res`-style files use raw `expect(...)->toEqual(...)` against `decide`/`evolve` directly. The migration to `StateChangeSlice_GWT` form is a structural change.

For the monorepo's ~8 DCB files: manual rewrite, single afternoon.

For downstream apps with hundreds: LLM-assisted route — feed the LLM the old test + the `StateChangeSlice_GWT` API, verify the new GWT against unchanged production code.

### C. E2E tests — unchanged

E2E tests dispatch real commands through the in-memory bus and count events. They're integration tests, not GWTs. Stay as-is. Long term they could be expressed as `Mapping_GWT` scenarios but that's a separate effort.

### D. Deprecation cleanup — after one release cycle

Delete `reventless-gwt/src/Deprecated.res` and `reventless-in-memory/src/test/Deprecated.res`.

---

## Dependencies and ordering

```
Stage 1 ──► Stage 2 ──┬─► Stage 3 ──┬─► Stage 4
                      │             │
                      │             ├─► Stage 5
                      │             │
                      │             └─► Stage 6
                      │
                      └─► Stage 7 ──► Stage 8
                                  └─► Stage 9
                                  └─► Stage 10
```

Stages 3, 4, 5, 6 can land in any order once Stage 2 is in.
Stage 8 (VS Code extension) needs Stage 7 (CLI) for the binary it spawns.
Stage 9 (PPX) needs Stages 1–6 to know what DSL kinds exist.
Stage 10 (docs) is the cleanup at the end.

Migration codemod A can land after Stage 1 (no dependency on the Outcome refactor — `JestBind` keeps the old behaviour).

---

## Out of scope

- **Snapshot testing** — not used by any GWT (snapshots and example-based GWT are different patterns).
- **Mocks/spies in the GWT layer** — slices are pure; no need.
- **Coverage tooling for GWTs** — line coverage isn't the right metric for example-based tests; if needed, run the Jest adapter alongside.
- **Replacing Jest for non-GWT tests** — component integration tests, infrastructure tests, the in-memory bus tests keep Jest. Only GWT files move to the new runner.
- **AI generation pipeline implementation** — Stage 5 of the analysis (§5.4) is its own follow-up plan; this plan ships the substrate it requires.

---

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Outcome algebra refactor breaks existing test files | Stage 2's `JestBind` adapter wraps each `test(...)` so test files compile unchanged. |
| `@send external` resolution breaks when DSLs move packages | All externals move into `reventless-gwt/src/AsyncTest.res`. Every downstream depends transitively on `reventless-gwt`. (See §6.1.1 of the analysis.) |
| LLM-assisted DCB test rewrite produces incorrect tests | Verify by running rewritten tests against unchanged production code; if they pass the same assertions, accept. |
| Watch mode resource leaks (chokidar handles) | `Cancellation.res` traps SIGINT/SIGTERM, closes watchers cleanly. |
| Output schema drift breaks AI prompts | `schemaVersion` field on JSON output; `--schema-version` flag downgrades. |
| PPX rebuild requires Docker | Documented in MEMORY; existing convention. |

---

## Estimated size

Rough line count for the runner (per analysis §3.3):

| Component | Lines (ReScript) |
|---|---|
| Outcome algebra + Hint | ~120 |
| Test discovery + loader + collector + argv | ~110 |
| RenderRescript + Diff (sury-aware) | ~200 |
| Five formatters | ~470 |
| Watch + cancellation + Bind/JestBind/AsyncTest | ~110 |
| **Runner subtotal** | **~1010** |
| Ten DSL modules (~150 lines each) | ~1500 |
| **Package total** | **~2500** |
| `reventless-vscode` extension (TypeScript) | ~80 |

Smaller than a typical Jest configuration with custom reporters and TAP/JUnit transformers, and closes the IDE story end-to-end.

---

## References

- [`docs/analysis/given-when-then-specifications.md`](../../analysis/given-when-then-specifications.md) — full design rationale, alternatives, format specifications.
- [`docs/analysis/event-source-connection-matrix.md`](../../analysis/event-source-connection-matrix.md) — cross-pattern producer/consumer combinations.
- [`docs/analysis/event-modeling-comparison.md`](../../analysis/event-modeling-comparison.md) — Event Modeling slice taxonomy.
- [`docs/guides/aggregate-vs-dcb-decision-guide.md`](../../guides/aggregate-vs-dcb-decision-guide.md) — when to use Aggregate vs DCB.
- VS Code Test API: https://code.visualstudio.com/api/extension-guides/testing
- TAP 14 spec: https://testanything.org/tap-version-14-specification.html
