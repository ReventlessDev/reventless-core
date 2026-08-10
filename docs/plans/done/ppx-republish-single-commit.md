# Plan: make a PPX source change a single commit

**Date:** 2026-08-09<br/>
**Status:** **COMPLETE — all six phases landed (2026-08-09/10).** A PPX source
change ships in one commit with CI/Release/deploy green throughout; scaffold
versions are generated from main so they can no longer desync; `publish-ppx.yml`
auto-commits the `optionalDependencies` pin after publishing; and a drift-guard
job validates the published artifact against source. See "Outcome" below.<br/>
**Role:** Removes the two-commit republish dance that every
`packages/reventless-ppx/src/**` change currently pays, and closes the gap that
let a stale binary pin reach `Release` and the deploys while CI stayed green.

## The problem

Shipping a PPX source change takes two pushes today:

1. Bump `npm/*/package.json` + main `version` in lockstep → push →
   `publish-ppx.yml` builds and publishes the per-platform binaries.
2. Bump `optionalDependencies` to the new version + relock → push.

Between the two, `Release` and the deploy workflows are **red**, because they
compile the new spec sources with the old published binary. Observed on the
`@live` republish (2026-08-09): `Release` run `31331831306` and
`Deploy Online Shop Hybrid` run `31331592164` both failed with
`Some required record fields are missing: live`, as did `publish-ppx.yml`'s
`Test PPX` job (run `31331592035`). CI (run `31331592030`) passed throughout —
see "Why CI lied" below.

## Root cause — three facts that compose

**1. The pin cannot precede the publish.** pnpm will not write a lockfile
resolution for a version that is not in the registry; an unresolvable
`optionalDependency` is silently dropped, leaving a `package.json`/lockfile
mismatch that fails `--frozen-lockfile` everywhere. So step 2 genuinely cannot
merge before step 1 has published. This constraint is not removable by
reordering commits.

**2. But the build does not need the pin.** `packages/reventless-ppx/bin`
resolves in this order: (1a) sibling in `node_modules`, (1b) nested under this
package, (2) `$DIR/ppx-<platform>.exe` — a locally built binary — and only then
(1c) an ancestor-directory walk. `.npmrc` sets `node-linker=hoisted`, so the
installed per-platform package always lands at the **workspace root**, which
the walk reaches **last**. A from-source `ppx-<platform>.exe` therefore
outranks the published binary in every in-repo build.

**3. The three workflows disagree about when they look for the binary**, so
only one of them gets fact 2's benefit:

| Workflow | Order | Effective binary | Result |
|---|---|---|---|
| `ci.yml` | check (`:122`) **before** install (`:177`) → always `present=false` | from-source (`:150`) | green |
| `release-packages.yml` | install (`:173`) **before** check (`:183`) → `present=true` | published (stale) | red at `Build release artifacts` (`:396`) |
| `deploy-online-shop-hybrid.yml` | no PPX step at all | published (stale) | red |
| `publish-ppx.yml` `Test PPX` | install (`:158`) **before** tests (`:178`) | published (stale) | red |

`release.yml:48` already passes `ppx-fallback: true` — the fallback is enabled
and merely **neutered by the ordering**: the check runs after the install, finds
the binary present, and skips the from-source build it was written to perform.

**4. Lerna owns main's version but not the scaffolds, so they re-desync after
every release.** `packages/reventless-ppx/npm/*/package.json` are not pnpm
workspace members (the `packages/*` glob is one level deep), so
`lerna version` bumps only the main package. Confirmed immediately after the
2026-08-09 release: main went to `1.0.0-alpha.64` while all three scaffolds
stayed at `1.0.0-alpha.63`.

This is harmless *right now* — main's `optionalDependencies` (`^1.0.0-alpha.63`)
still resolve to the published `alpha.63` binaries — but it is the seed of the
next incident. `publish-ppx.yml` publishes the version written **in the
scaffold**, so the next source change that bumps only main publishes nothing and
still reports success (the publish step's error is swallowed for the
already-exists case). Every republish therefore starts by re-synchronising four
files by hand, which is the step most likely to be forgotten.

### Why CI lied

`ci.yml`'s check runs before dependencies exist, so it *always* reports the
binary missing and *always* builds the PPX from source. Two consequences:

- CI has been immune to stale-pin problems by accident, not by design — it
  structurally **cannot** catch this class of failure. Release and the deploys
  are the only honest signals today.
- Every CI run pays an OCaml build the workflow was explicitly written to skip
  in the healthy case (see the comment at `ci.yml:127-133`).

## Options

**A. Uniform from-source PPX for all in-repo builds (recommended).** Make
fact 2 deliberate: build the PPX from source before any ReScript build in every
workflow. Nothing in-repo then resolves the published binary, so the pin stops
gating anything.
- One commit per PPX change; the tree stays green throughout.
- Cost: an OCaml build per workflow (~1 min with `dune-cache`); `ci.yml`
  already pays it today.
- Trade-off: the repo stops validating the *published* artifact, so source and
  binary could drift. Mitigated by Phase 3.

**B. Automate the second commit.** Have `publish-ppx.yml` push the
`optionalDependencies` bump + relock itself after a successful publish.
- Keeps "the repo validates the published artifact".
- Does **not** close the red window between the two commits — it only removes
  the human step. Worth doing *with* A, not instead of it.

**C. Fix only `release-packages.yml`'s ordering.** The smallest change that
would have made this episode green, but it lands the same trade-off as A
without stating it, and leaves the deploys uncovered.

**Recommendation: A, then B.** A removes the coupling; B removes the leftover
housekeeping commit. C is subsumed by A.

## Phases

1. ✅ **Composite action.** Add `.github/actions/setup-ppx` that builds the PPX
   from source with `dune-cache` and writes
   `packages/reventless-ppx/ppx-<platform>.exe`. Idempotent and cheap on a warm
   cache.
2. ✅ **Adopt it** in `ci.yml`, `release-packages.yml`, and the deploy workflows,
   before any build step — replacing the current check/fallback pair and the
   now-misleading `ppx-fallback` input. Verify by re-running a release on a
   deliberately stale pin: it must go green.
3. ✅ **Drift guard.** Add a job to `publish-ppx.yml` that, after publishing,
   reinstalls the just-published package and asserts it compiles an annotated
   fixture byte-identically to the from-source binary. This is what buys back
   the validation A gives up; without it, a packaging regression could ship
   unnoticed.
4. ✅ **Generate the scaffolds' version instead of hand-maintaining it** (root
   cause 4). Have `publish-ppx.yml` write each `npm/<target>/package.json`
   version from the main package's version immediately before `npm publish`, so
   the two can never disagree and "bump main" becomes the single source of
   truth. Also make the publish step fail loudly on a no-op publish rather than
   swallowing it, so a missed bump cannot report success. Keep the lockstep
   sanity check in `scripts/publish-ppx-local.mjs` — with generated versions it
   becomes an assertion that should never fire.
5. ✅ **Automate the pin commit** (option B): after a successful publish, push the
   `optionalDependencies` bump + relock. Must not re-trigger a release loop —
   follow the existing `[skip ci]` convention used by
   `chore(release): version packages`.
6. ✅ **Update the runbook.** `docs/plans/prebuilt-binaries-out-of-repo.md` and the
   PPX guidance describe the two-step dance as mandatory; both need revising
   once phases 1–5 land.

## Verification

The regression this plan prevents is specific and reproducible: add a required
field to `StateAnnotations.stateAnnotationSpec`, emit it from the PPX, and push
**without** republishing. Before this work: `Release` and the deploys fail with
`Some required record fields are missing: <field>` while CI is green. After:
all three are green, and the drift guard is the only job that cares whether the
registry is current.

## Outcome (2026-08-09/10)

**Landed — Phases 1, 2, 4, 5, 6:**

- `.github/actions/setup-ppx/action.yml` — composite action: `ocaml/setup-ocaml`
  (dune-cache) → `dune build` → stage at `packages/reventless-ppx/ppx-linux.exe`
  (the bin resolver's local fallback, which outranks the hoisted published
  package). Linux-only, matching the ubuntu-latest runners that use it.
- `ci.yml` — the check + two fallback steps collapse to one `uses:
  ./.github/actions/setup-ppx` step. CI already built from source on every run;
  this just makes it deliberate and shared.
- `release-packages.yml` — the check/fallback trio is replaced by the composite
  action, run **unconditionally when `ppx-fallback: true`** (no more "is the
  binary present?" probe that used to find the stale install and skip the
  build). `release.yml` drops the now-unused `ppx-binary-paths`.
- `deploy-reventless-aws.yml` — both build jobs (`deploy-platform`,
  `deploy-plugins`) gained the composite action, gated on a new
  `build-ppx-from-source` input. The two in-repo wrappers
  (`deploy-online-shop-{hybrid,aggregates}.yml`) set it `true`.
- Docs: this repo's runbook (`prebuilt-binaries-out-of-repo.md`),
  `publish-ppx.yml`'s header, and the `@offload` note in
  `.claude/rules/app-developer.md` no longer call the pin bump a hard
  prerequisite — it is now lazy housekeeping for external consumers.
- `publish-ppx.yml` — new `preflight` job (`build` gains `needs: preflight`)
  that reads main's version and, **on push only**, fails if it is already on the
  registry (a forgotten bump would otherwise no-op every publish and report
  success). A new "Sync per-platform version from main" step in `build`
  `npm pkg set`s each scaffold's version from main immediately before publish, so
  `npm/<target>/package.json` can never drift behind main (lerna bumps only the
  main package — `npm/*` is not a workspace member). `scripts/publish-ppx-local.mjs`
  (the darwin-x64 manual path) does the same generation, replacing its
  version-skew warning. The three committed scaffolds were resynced from
  `alpha.63` → `alpha.64` (main's current version) as a one-time coherence fix;
  going forward the value is cosmetic since publish regenerates it.
- `publish-ppx.yml` — new `pin` job (`needs: [preflight, build, publish-main,
  drift-guard]`, `contents: write`) that, once the new binaries and main package
  are on the registry and the drift guard is green, rewrites main's
  `optionalDependencies` to `^<version>`, relocks (`pnpm install --lockfile-only`,
  retried to ride out registry propagation), and commits + pushes
  `chore(ppx): pin the <ver> binaries now that they are published [skip ci]`.
  This is the automated form of the previously-manual second commit (e.g.
  `2e8d076fd`). Loop-safe: the commit touches only `package.json` +
  `pnpm-lock.yaml` (never `src/**`) and carries `[skip ci]`, and a `GITHUB_TOKEN`
  push does not trigger workflows regardless. Idempotent — a re-dispatch where the
  pin is already current commits nothing.
- `publish-ppx.yml` — new `drift-guard` job (`needs: [preflight, build]`) that
  `npm pack`s the just-published `linux-x64` binary (retried for registry
  propagation) and runs the maintained PPX suite (`test/run.sh`) through it: if
  the published artifact drifted from source, the suite's source-tracking
  assertions fail here. This buys back the published-artifact validation that
  building from source everywhere gave up — nothing else in-repo resolves the
  published binary anymore. Two backward-compatible knobs were added to `run.sh`:
  `REVENTLESS_PPX_BIN` (point the fixtures at a specific binary) and
  `REVENTLESS_PPX_SKIP_SELF_BUILD` (skip the source dune build — the guard needs
  no OCaml). `pin` now also `needs: drift-guard`, so a bad publish never gets
  pinned onto consumers.
- `publish-ppx.yml` **`test` (Test PPX) job now tests SOURCE**, via
  `REVENTLESS_PPX_BIN` → the from-source `bin.exe`. It previously compiled the
  current spec fixtures with the launcher-resolved *installed* (pinned, stale)
  binary — its own `dune build` is only a self-test that is never wired to the
  fixtures — so it went red on any PPX change that added a `run.sh` assertion,
  gating PPX source changes behind a republish. Testing source keeps it green in
  the same commit (the `drift-guard` job covers the published artifact
  separately). This was the last piece of the single-commit-green story for
  `publish-ppx.yml` that Phase 2 left unspecified.

**Deliberate deviations from the written plan:**

- **`ppx-fallback` is kept, not removed.** Phase 2 says "replace the
  now-misleading `ppx-fallback` input," but the input is the on/off switch that
  keeps **external** callers of the reusable `release-packages.yml` /
  `deploy-reventless-aws.yml` (other repositories that consume this repo's
  published packages) from attempting a from-source build they have no
  `packages/reventless-ppx/src` for.
  So the input stays as the gate; only its *meaning* changed (from
  "build-from-source-as-fallback" to "build-from-source-always"), and its
  description was rewritten to match. `ppx-binary-paths` is kept **declared but
  unused** (removing a declared input errors any caller still passing it) and
  marked DEPRECATED. Same reasoning added the `build-ppx-from-source` gate to
  the deploy workflow rather than hard-wiring the step.
- **Phase 4's "fail loud on no-op publish" is a preflight gate, not a change to
  the publish step.** The plan wording ("make the publish step fail loudly on a
  no-op publish") would break legitimate idempotent re-runs — a manual
  re-dispatch, or a partial-failure re-run where one platform already published.
  Instead the new `preflight` job fails the whole run early **on push** when
  main's version already exists (the only case that means a bump was forgotten),
  while the per-platform publish steps keep their already-exists tolerance for
  re-runs. Same intent ("a missed bump cannot report success"), without the
  collateral.

- **Phase 3's drift guard reuses `test/run.sh`, not a bespoke `bsc -dsource`
  diff.** The risk the plan flagged is a mis-wired guard that exercises the
  from-source binary on both sides — a green rubber-stamp. Running the *maintained*
  suite through the *published* binary sidesteps that: the fixtures compile with
  the fetched published `ppx.exe` (via `REVENTLESS_PPX_BIN`) and are asserted
  against expectations that track source, so a stale/regressed published binary
  fails real assertions. It also inherits full feature coverage for free (every
  PPX feature already adds `run.sh` assertions) instead of relying on one
  hand-written fixture. Only proven in CI, as the plan notes.

## Explicitly out of scope

- Changing the per-platform packaging model (`optionalDependencies` +
  `os`/`cpu`) — it is the right shape for external consumers and is not what
  makes the flow two-step.
- The `darwin-x64` manual publish path, which is a separate constraint (no
  Intel runner in the matrix) and unaffected by any of the above.
