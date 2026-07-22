# Close the CI unit-test coverage gap for core, spec and interop

**Status:** In progress (2026-07-22). **aws slice DONE** — see below. The remaining work hinges
on one decision that touches published-package semantics.
**Owner:** Martin
**Found:** while verifying `docs/plans/done/retire-stale-admin-vocabulary.md` (commit `2770bd96f`).
Wanting to run `CommandAuthorizationTest` and `Auth_CognitoTest` to prove that rename hadn't
moved the authz boundary, neither turned up under root `pnpm test`. They exist and pass — CI
simply never ran them.

**Motivation:** several packages' unit tests never execute in CI. All are green when run
directly, so this is dark coverage, not broken tests. Nothing is failing; the risk is that
nothing would report it if it did.

| Package | `*Test.res` | Runs in CI? | Measured |
|---|---|---|---|
| `reventless/local` | 73 | ✅ yes | — |
| `reventless/gwt` | 14 | ✅ yes | — |
| `reventless/aws` | 28 | ✅ **now yes** | 21 suites / **280 tests** (7 integration, excluded by design) |
| `reventless/core` | 49 | ❌ **no** | 49 suites / **518 tests** pass |
| `reventless/spec` | 10 | ❌ **no** | 10 suites / **103 tests** pass |
| `reventless/interop` | 3 | ❌ **no** | 3 suites / **50 tests** pass |

**Remaining gap: 62 suites / 671 tests**, including the whole framework core.

## Done — the aws slice (2026-07-22)

aws was separable because its test outputs are tracked and present in a fresh clone; it was
missing only a jest project. Root `pnpm test` went **169 → 190 suites, 1113 → 1393 tests**.

- Added a `reventless-aws` project to `jest.config.js`, carrying over the package's own
  `testPathIgnorePatterns` so `tests/integration/` and `Pg.*IntegrationTest` stay owned by
  `test:integration` / `test:integration:pg` and don't double-run.
- Used the **root** `jest.setup.cjs` rather than the package's own — the root one is a superset,
  adding the `structuredClone` polyfill that keeps DynamoDB `TransactionCanceledException`
  detail from being masked. The package-local setup lacks it, so this is a small improvement
  on top of merely wiring the project up.
- Added CI affected-path mappings for `reventless/aws/` and `reventless/gwt/`, and removed the
  now-inaccurate `e.g. reventless-aws` from the `select=none` comment. Simulated the selector:
  aws-only → `reventless-aws`, gwt-only → `reventless-gwt`, core/spec → `all`, docs → `none`.

---

## Remaining: core, spec, interop

### Cause 1 — `"type": "dev"` suppresses test outputs on the root build

Root `rescript.json` has `"sources": []` and lists every package as a **dependency**. ReScript
skips `type: "dev"` source entries when building a package as a dependency — and the root
build's clean step removes any that a previous per-package build had emitted.

| Package | `tests` entry in its `rescript.json` | `.res.mjs` on disk after root build | Tracked |
|---|---|---|---|
| core | `{"dir":"tests","subdirs":true,"type":"dev"}` | **0** | 0 |
| spec | `…"type":"dev"` | **0** | 0 |
| interop | `…"type":"dev"` | **0** | 0 |
| local | `{"dir":"tests","subdirs":true}` | 73 | 108 |
| aws | `{"dir":"tests","subdirs":true}` | 28 | 38 |
| gwt | `{"dir":"tests","subdirs":true}` | 14 | 22 |

The correlation is exact. Jest matches `<rootDir>/tests/**/*Test.res.mjs`; with zero `.res.mjs`
on disk it discovers zero suites and **exits 0** — a silent pass, not an error.

Verified directly: `cd reventless/core && pnpm run build` emits 49 test outputs; a subsequent
root `pnpm run build` removes them again. Re-confirmed after a clean
`pnpm install --frozen-lockfile`, so this is not an install artifact.

### Cause 2 — `reventless-spec` has no jest project

`jest.config.js` still has no `reventless-spec` entry. Adding one is necessary but **not
sufficient** — spec also has zero outputs (Cause 1). `reventless-core` and `reventless-interop`
projects already exist and discover 0 for the same reason.

### The decision

| | Approach | Cost / risk |
|---|---|---|
| **A** | Drop `"type": "dev"` from core/spec/interop, matching local/aws/gwt | **Risks a known regression.** `type: "dev"` on spec was added deliberately to fix release-mode consumer builds — without it, a consumer compiling the published package pulls in `tests/`, which needs the `rescript-jest` devDependency. Do not take this without re-testing that path. |
| **B** | Track the test `.res.mjs` for core/spec/interop, as local/aws/gwt already do | **Fights the build.** The root build's clean step deletes these files, so every root build would leave tracked deletions in the working tree. Hit twice during the Admin rename. Not viable while Cause 1 stands. |
| **C** ✅ | Add an explicit per-package build step in CI before the test step | Additive. No change to published-package semantics, no new tracked generated files, no consumer risk. Costs CI time and reintroduces the per-package build orchestration `CLAUDE.md` set out to avoid. |

**Recommendation: C**, unless the release-mode concern behind A turns out to be obsolete — which
should be settled by actually testing a release-mode consumer build, not by assumption. A is
strictly simpler if it holds.

## Steps

1. ~~Assert in CI that no jest project silently discovers zero suites.~~ **DONE 2026-07-22** —
   `scripts/check-jest-projects.mjs`, wired as `pnpm run test:projects` and a CI step gated on a
   successful build. Asserting a total suite *count* was rejected as brittle (it breaks whenever
   anyone adds a test file); the check instead requires **every declared project to discover ≥1
   suite**, which is robust to normal test growth and targets the actual failure mode.
   `reventless-core` and `reventless-interop` are in an explicit `KNOWN_EMPTY` allowlist so CI
   stays green on the documented gap — and the check *also* fails if a listed project starts
   discovering suites, forcing the allowlist to shrink as steps 2–3 land. Both directions were
   verified by simulation.
2. Add a `reventless-spec` project to `jest.config.js`, mirroring its package `jest` field.
   (Necessary but not sufficient — spec also has zero outputs.)
3. Per-package build step (Option C): in `ci.yml`, after `pnpm run build`, build
   `reventless/spec`, `reventless/core` and `reventless/interop` individually so their
   `type: "dev"` test outputs exist when jest runs. Order matters — spec before core.
4. Remove each package from `KNOWN_EMPTY` as it starts working. The check enforces this: leaving
   a now-working project in the list is itself a failure.
5. Root `pnpm test` should then report **252 suites** (190 today + 49 core + 10 spec + 3 interop).
6. Consider the `select=none` fallback separately — skipping the entire test step is what let
   this hide. A minimal smoke project would mean "no mapping" never equals "no signal".

## Done when

- Root `pnpm test` discovers and runs the core, spec and interop unit suites.
- ~~A package silently dropping to zero suites fails CI.~~ **DONE** — `pnpm run test:projects`.
- `KNOWN_EMPTY` in `scripts/check-jest-projects.mjs` is empty, and the check enforces every
  declared project.
- `test:integration` / `test:integration:pg` still own the 7 aws integration suites — no
  double-execution. *(Holds as of the aws slice; re-check after any further config change.)*

## Non-goals

- **Changing the tracked-`.res.mjs` convention** documented in `CLAUDE.md`. Option C is chosen
  precisely to avoid touching it.
- **Publishing / release-mode behaviour.** Option A would touch it; C does not.
- **The 4 "failing" hybrid example suites — RESOLVED 2026-07-22, no repo change.** They failed
  locally with `Cannot find module '@reventlessdev/online-shop-hybrid-ordering-spec/src/…'`.
  Cause was a local install gap: `examples/online-shop-hybrid/catalog` and `.../ordering` were
  the only two workspace packages with no `node_modules`, and those suites are the only ones
  importing a sibling spec package (jest resolves that via the package's own `node_modules`).
  `pnpm install --frozen-lockfile` fixed it; lockfile untouched. CI was never affected — it
  installs fresh.

  Two diagnostic notes worth keeping: (a) the repo's custom jest reporter swallowed the real
  error and surfaced only "import after teardown" spam plus a misleading `(0 tests)` PASS line —
  `--reporters=default` showed the actual cause immediately; (b) confirming a failure is
  "pre-existing" by stashing to HEAD only rules out *source* causes, since `git stash` leaves
  `node_modules` untouched. Both cost time here.

## Unverified

- Whether the release-mode consumer-build problem that motivated `"type": "dev"` on spec still
  reproduces. If not, Option A replaces C.
- Whether adding ~62 suites materially changes CI wall-clock. The aws slice added 21 suites and
  the full run got *faster* in wall-clock terms on a warm cache, so the expected cost is the
  extra build step, not the tests.
