# Jest Bindings Consolidation — One Binding Package, Five Local Modules Retired

## Executive Summary

The repo hand-rolls Jest bindings in **five near-identical per-package modules** because
ReScript module visibility is per-package: a `tests/` module in one package cannot be
reused by another, so each package that needed async-capable, throwing-expect bindings
re-wrote them. Consolidate into **one workspace binding package** at the bottom of the
dependency graph, migrate consumers with zero behavioral risk, and — as a separable
final stage — decouple `reventless-gwt`'s jest mode from `@glennsl/rescript-jest` so the
third-party library can be removed repo-wide.

The duplicated modules (survey 2026-06-12):

| Module | Used by | Style |
|---|---|---|
| `reventless-core/tests/AsyncTest.res` | core tests; consumed cross-package by reventless-local tests (`Reventless.AsyncTest`, incl. `beforeAllAsync`) | jest globals + `testPromise` |
| `reventless-gwt/src/AsyncTest.res` | gwt tests | same family |
| `rescript/rescript-effect/tests/AsyncTest.res` | effect tests | same family |
| `reventless-aws/tests/TestHelpers.res` | aws tests | jest globals + package-specific helpers |
| `reventless-codegen/tests/JestBind.res` | all 12 codegen suites | jest globals, async `test`, timeout/skip variants |

**Constraint discovered in the same survey:** `@glennsl/rescript-jest` is declared in
**16 packages** and is **load-bearing inside `reventless-gwt`** — gwt's
`src/JestBind.res` (the jest-vs-Collector router, *not* one of the duplicates) delegates
to glennsl's `Jest.test` in jest mode, and `PackageScaffoldEmitter` emits the glennsl
dev-dependency into every generated plugin (goldens, examples). glennsl cannot be
dropped before Phase 3.

**Why glennsl is not the consolidation target itself:** its assertion model is
deferred-by-design — `expect |> toBe` builds a value that only executes if *returned*
(one affirmed assertion per test). Mid-test assertions are silently inert: a forgotten
return passes green. Verified against the latest release (0.13.1, 2025-12; already
pinned here): the model is unchanged. The repo's local modules all exist to get Jest's
*throwing* `expect` (every assertion executes at its line) plus native `async () => ...`
test bodies.

**Estimated size:** S for Phases 0–1, S per package for Phase 2, M for Phase 3.

---

## Decisions

| # | Question | Decision |
|---|----------|----------|
| 1 | Where does the shared binding live? | **New package under `rescript/`** (bindings for a JS lib → `rescript/`, per repo placement rules). Bottom of the dependency graph, no deps of its own — the only placement that `rescript/*` packages (e.g. rescript-effect), framework packages, codegen, and plugins can all legally depend on. Putting it in `reventless-gwt` was rejected: `rescript/*` test suites must not depend on a framework package (layering inversion). |
| 2 | Package name | **RESOLVED: `@reventlessdev/rescript-jest`** (matches the repo's bind-the-lib naming). Module name is `JestGlobals` (the package is `namespace: false`); `Jest`/`JestBind`/`AsyncTest`/`TestHelpers` were all unavailable as the global module name (collisions). |
| 3 | Binding style | **Direct bindings to Jest globals with throwing `expect`** — the JestBind/AsyncTest style, NOT glennsl's deferred-assertion model. Surface = superset of the five modules: `describe`, `test` (async `unit => promise<unit>`), `testSync`, `testWithTimeout`, `testSkipWithTimeout`, `only` variants, `beforeAll`/`afterAll`/`beforeEach`/`afterEach` (+ async aliases `beforeAllAsync` etc. for AsyncTest compat), `expect` + the matcher set actually used (`toBe`, `toEqual`, `toBeTruthy`, `toBeFalsy`, `toContain`, plus whatever the aws/core module survey turns up). |
| 4 | Migration mechanics | **`include`-shim first, rename-opens later.** Each local module's body collapses to `include <SharedModule>` (+ genuinely local helpers, e.g. parts of aws `TestHelpers`): de-duplication lands immediately with a few-line diff per package and zero churn in ~50 test files. Deleting the shims (rewriting `open AsyncTest` → the shared open) is a separate mechanical pass per package. Exception: codegen skips the shim — 12 files, one rename pass, delete `JestBind.res` outright. |
| 5 | `reventless-gwt/src/JestBind.res` (Collector router) | **Out of scope as duplication — it stays.** It is runner infrastructure (routes describe/test to Jest or the gwt CLI Collector). Its jest-mode arm is rebuilt on the shared package only in Phase 3. |
| 6 | `@glennsl/rescript-jest` | **Keep wherever load-bearing until Phase 3.** Phase 0 removes it only from packages where it is verifiably unused (codegen). Phase 3 removes it from gwt, the scaffold emitter, and then repo-wide. |

---

## Phase 0 — Shared package + codegen migration (S)

- Create `rescript/<name>/` (Decision 2) following rescript-uuid conventions:
  `package.json` (no runtime deps; rescript peer), `rescript.json`
  (`namespace: false`, in-source esmodule, `.res.mjs`), one `src/` module per
  Decision 3. Seed from codegen's `JestBind.res` (the most recently exercised
  superset) merged with the four siblings' extras — survey each before writing.
- Codegen: add the workspace dep (package.json + rescript.json), rewrite the 12
  suites' `open JestBind` to the shared open, **delete `tests/JestBind.res`**, and
  drop the unused `@glennsl/rescript-jest` from codegen's package.json/rescript.json.
- Do NOT carry over JestBind's stale header comment ("testPromise does not await") —
  the accurate rationale is glennsl's one-affirmed-assertion-per-test model; record it
  in the new package's module doc.

**Verification:** codegen suite green (90 + gated skip), zero warnings, goldens
byte-clean.

## Phase 1 — Shim the remaining four modules (S)

- `reventless-core/tests/AsyncTest.res`, `reventless-gwt/src/AsyncTest.res`,
  `rescript/rescript-effect/tests/AsyncTest.res` → body becomes
  `include <SharedModule>` (+ any local-only bindings kept explicitly).
- `reventless-aws/tests/TestHelpers.res` → jest-binding portion replaced by the
  include; aws-specific helpers stay.
- Wire the workspace dep into each package.
- **Watch item:** reventless-local's tests consume core's `AsyncTest` cross-package
  (`Reventless.AsyncTest`, incl. `beforeAllAsync`) — confirm the include preserves the
  exposed surface (names AND arities) before touching core.

**Verification:** full monorepo test run green; zero new warnings in each touched
package.

## Phase 2 — De-shim (S per package, mechanical, schedulable independently)

- Per package: rewrite `open AsyncTest` / helper opens to the shared open, delete the
  shim module. One package per PR-sized change; no behavior change expected.
- End state of Phases 0–2: exactly one Jest binding for hand-written tests repo-wide.

## Phase 3 — Decouple reventless-gwt's jest mode from glennsl (M, separate effort)

The real refactor; everything above is risk-free de-duplication.

- Rework gwt's jest-mode assertion path: the `*_GWT.Make` functors currently convert
  `Outcome.outcome` into glennsl `assertion` values (`toAssertion` in gwt's JestBind);
  replace with throwing semantics (direct `fail(Outcome.format(mismatch))` or the shared
  package's throwing `expect`). The CLI/Collector arm is untouched.
- `PackageScaffoldEmitter`: stop emitting the `@glennsl/rescript-jest` dev-dependency
  into generated plugins → regenerate goldens (byte-diff review), update example
  plugins and the platform-and-plugin guide if it mentions the dep.
- Remove glennsl from gwt, then sweep the remaining declarations (16 found in the
  survey: examples/*, goldens, rescript-moment, aws, core, interop, local) — each needs
  a uses-check first; some may have their own direct usage.
- **Risk:** this touches the functor surface every plugin's `_GWT.res` tests compile
  against — needs a full-workspace build + example-plugin test runs, and a check that
  generated plugins' `rescript.json` dev-dependencies stay consistent with what their
  compiled test code actually imports.

**Verification:** monorepo green; a freshly `forward`-generated plugin builds and runs
its GWT both via jest and via `reventless-gwt run`; `grep -r glennsl` over
package.json/rescript.json returns nothing.

---

## Out of scope

- Replacing Jest itself (vitest/bun/zora — different runners, different effort class).
- gwt's Collector/runner architecture.
- The synthesis pipeline (Plan 07) — unaffected; its suites just ride the codegen
  migration in Phase 0.

## Risks and Mitigations

| Risk | Mitigation |
|------|-----------|
| Shared-module surface misses a name/arity some package relied on | Survey all five modules before writing the package (Phase 0); shims keep old module names alive until Phase 2, so a miss is a compile error in one package, not a silent break. |
| Cross-package consumers of core's `AsyncTest` (reventless-local) break | Explicit watch item in Phase 1; include preserves the exported surface; full monorepo test run gates the phase. |
| Phase 3 functor changes ripple into every plugin's GWT tests | Phase 3 is its own effort with full-workspace verification; Phases 0–2 land independently and first. |
| Golden fixtures churn when the scaffold emitter changes | Regenerate via the existing ForwardGoldenTest flow; review the byte-diff; goldens are already normalized for comparison. |
| Name collision confusion with upstream `@glennsl/rescript-jest` | Decision 2 resolves before Phase 0; scope prefix disambiguates in either case. |

---

## Outcome (completed 2026-06-12)

All four phases shipped. `@glennsl/rescript-jest` is gone repo-wide (0 refs in any
`package.json` / `rescript.json` / `pnpm-lock.yaml`). Whole monorepo builds with
zero warnings; every suite green — codegen 90 (+1 gated skip), core 411, gwt 108,
aws 114, effect 141, interop 31, moment 116, local 446, all six example plugins,
goldens byte-clean, and a freshly-`forward`-generated plugin runs its GWT via both
`jest` and `reventless-gwt run`.

Deviations and discoveries beyond the written plan:

- **Module name `JestGlobals`, not a `Jest`/`JestBind` shim name** — those collide
  with existing global modules. Package is `namespace: false`.
- **Surface is `module Runner` + `module Expect`, re-exported flat at the top
  level** — a plain `include <Shared>` (Decision 4) caused a warning-44 `toBe`
  shadow in every file that pairs `open X` with `open X.Expect` (core/gwt/effect/
  local, ~90 files). The split lets the AsyncTest re-exports expose `Runner` flat +
  `Expect` as a submodule (no shadow), while flat users (codegen, aws) open the
  whole module. The warning even crashed rescript v12's build orchestrator
  (Utf8Error on the box-drawing chars), so it was a hard blocker, not cosmetic.
- **All `@val` externals are bound via `@scope("globalThis")`.** gwt's `JestBind`
  defines its own `let test`; a bare `test`/`expect` emitted by the externals
  resolved to that local binding at runtime (`testPromise` called the wrong
  `test`, "first argument must be a string"). Scoping to `globalThis` makes the
  bindings immune to any local shadow. This regenerated ~143 in-source `.res.mjs`
  (`test(` → `globalThis.test(`) — output-only, no semantic change.
- **`expect` stayed opaque (`expectResult`), not typed like glennsl's
  `expect<'a>`.** Typing it would have re-validated every already-green
  opaque-era assertion (codegen/aws/effect/local). The one file that relied on
  glennsl's typed `expect` to disambiguate constructors — `DcbDecodeTest`, which
  defines four types all named `ItemCreated`/`ItemArchived` — got local
  `let expected: option<...> = …` annotations instead.
- **Cross-package consumer reality differed from the plan's note:** the heavy
  consumer was `ReventlessGwt.AsyncTest` (~61 reventless-local files), plus
  effect's bare `AsyncTest` (the 4 `LocalAuth*` files). `rescript-jest` had to be
  added to `reventless-local`, `reventless-interop`, and `rescript-moment` too.
- **Matcher surface grew past the plan's list:** added `toHaveLength`,
  `toBeGreaterThan`, `toBeGreaterThanOrEqual`, `toBeCloseTo`, `not_`, and a
  throwing `fail` (Jest 27 ESM removed the global `fail`).
- **Naming convention `test` = async / `testSync` = sync** (seeded from codegen,
  matches Jest's idiom that the unmarked `test` accepts async; `testPromise` /
  `testAsync` are async aliases). This is the *opposite* of glennsl's
  `test` = sync — deliberate, and irrelevant to reversibility since the
  throwing-vs-deferred assertion model already makes a swap back impossible.
- **Two test fixes the migration surfaced:**
  - `MomentTest #isSameOrBeforeWithGranularity` — glennsl's deferred model had
    masked a wrong assertion (`->ignore`d, never run). The throwing model exposed
    it; the expected value was corrected to match reality.
  - `ManifestVisibilityTest` "Plugin_Structure.make" block — a pre-existing red
    (unrelated to bindings): commit `ff65d0c2c` filtered Internal read models out
    of `pluginStructure`, but `6a6e5e466` ("show Internal components in the dev
    graph") reversed that to *carry + tag* and left the assertion stale. Updated
    to assert the current carry-and-tag contract (length 2, Internal tagged
    `Some("Internal")`).
- **Effect's `arrayFrom` helper** (a Chunk→array util, not a Jest binding) moved
  to a local `rescript-effect/tests/ChunkHelpers.res` rather than into the shared
  package.
