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
| 2 | Package name | **OPEN — decide before Phase 0.** Candidates: `@reventlessdev/rescript-jest` (matches the repo's bind-the-lib naming: rescript-uuid, rescript-mcp-sdk; shadows the upstream name only under our scope) vs `@reventlessdev/rescript-jest-globals` (collision-proof, blander). |
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
