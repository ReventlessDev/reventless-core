# Plan: the repo and its Lambdas run on Node 24

**Status.** Done 2026-11-07. Planned 2026-11-06; [NU1](#nu1-the-toolchain) was done the same
day, [NU2](#nu2-the-lambdas) and [NU3](#nu3-close-the-loose-ends) the next.

**In plain words.** Node is the JavaScript runtime that everything here runs on: the build, the
tests, the local platform and every deployed Lambda. We pin 22.17.1. Node 22 is in maintenance
until 2027-04-30, and Lambda deprecates `nodejs22.x` that day. Effect 4, our next big
dependency move, needs 22.19 or newer
([the Effect 4 analysis, EVQ2](../../analysis/effect-v4-migration.md#6-open-questions)). Moving now,
and on its own, means a test that breaks during the Effect work is Effect's doing, not Node's.

**Target: Node 24.22.2.** It is the active LTS, and Lambda's `nodejs24.x` is supported until
2028-04-30. Node 22.23.4 would clear the Effect floor too, but it would leave us doing this again
in six months. Node 26 became LTS on 2026-10-28, but on Lambda it is still a preview runtime that
AWS says not to use in production.

**Steps.** They are numbered NU1 to NU4. Each of NU1 and NU2 is one commit.

---

## NU1 The toolchain

Local and CI move to 24.22.2. Nothing deployed changes.

- [.node-version](../../../.node-version) (fnm and nvm read it).
- Every `node-version: "22.17.1"` in [.github/workflows/](../../../.github/workflows/), and the
  `node-version` input default of `release-packages.yml`.
- The Node lines in [README.md](../../../README.md), [CLAUDE.md](../../../CLAUDE.md) and
  [the CI/CD setup guide](../../guides/CICD_SETUP.md).

**Done when:** on Node 24, a full `pnpm run build` has zero warnings, `pnpm test` is green, and
`pnpm run test:projects` finds suites in every project. The places most likely to notice are
`node:sqlite` in the local platform
([SqliteDriver.res](../../../reventless/local/src/adapter/SqliteDriver.res)) and Jest 29's ESM mode.

**Result:** done. On 24.22.2 the build has zero warnings, `pnpm test` passes 524 suites (5791
tests), and `test:projects` finds suites in all 21 projects. There are no native addons, so
`node_modules` did not need a reinstall. The deploy workflow's own `node-version` default (`"22"`,
the Node that runs Pulumi) moved too. Sibling repos keep their own pins, and
`reventless-sovereign` calls `release-packages.yml` at the `release-packages-v1` tag, which this
does not move.

## NU2 The Lambdas

Deployed functions move to `nodejs24.x`.

- The 12 functions that set `"nodejs22.x"` go behind one constant,
  [Util_LambdaRuntime.res](../../../reventless/aws/src/util/Util_LambdaRuntime.res), so the next
  move is a one-line change. The module has no imports, so the deploy script can read it
  without loading Pulumi.
- The layer's compatible runtimes, in
  [build-lambda-layer.yml](../../../.github/workflows/build-lambda-layer.yml) and
  [DeployApp.res](../../../reventless/aws/scripts/DeployApp.res), drop `nodejs20.x` (end of life
  since 2026-04-30) and become `nodejs22.x` + `nodejs24.x`. 22 stays listed so functions still on
  it keep a matching layer during the switch.
- The `CallbackFunction` runtime type in
  [the Pulumi Lambda binding](../../../rescript/pulumi-aws/src/Lambda/Lambda.res) gains `NodeJs24`.

**Checked before the deploy:**

- *Callback handlers.* Lambda's `nodejs24.x` refuses callback-style handlers
  (`Runtime.CallbackHandlerDeprecated`); only async and plain synchronous ones run. Every handler
  behind the 12 functions is `async`.
- *Pulumi.* `@pulumi/aws` 7.19 lists `nodejs24.x` in its runtime enum.
- *Left as it is:* the legacy `CallbackFunction` path in
  [RuntimeEnvironment_Lambda.res](../../../reventless/aws/src/adapter/Runtime/RuntimeEnvironment_Lambda.res)
  passes no runtime, so Pulumi gives it `nodejs20.x` and ignores later runtime changes. It is
  reachable only through a side-effect-bearing Task and is already broken in other ways. Its
  conversion to a compiled entry point is
  [its own plan](../task-sideeffect-callbackfunction-conversion.md). The conversion moves it onto
  `makeFromCodeAsset`, and so onto the constant.

**Done when:** the hybrid example deploys. A deployed function reports `process.version` 24.x.
A command runs through both the sync and async handlers, and its projection updates. The custom
import loader that resolves packages from the layer is the part most likely to break, because
it is built on Node's module hooks.

**Result:** done, deployed together with the Effect 4 migration. The 34 functions the deploy
updated run `nodejs24.x` and report `nodejs:24.mainline.v115` at start; the layer lists
`nodejs22.x` and `nodejs24.x`. Commands ran through the sync and the queue-fed handlers and their
views updated; the example deploys no async command handler. The custom import loader needed no
change. What broke was the release, not the runtime:

- npm 11, which ships with Node 24, refuses a prerelease published without `--tag`, so
  [release-packages.yml](../../../.github/workflows/release-packages.yml) now names `latest` when
  it does not dist-tag prereleases. `reventless-sovereign` pins the workflow at
  `release-packages-v1` and gets this only when that tag moves.
- `check-union-reachability.mjs` crashed in a Pulumi mock race under Node 24 after reporting
  its result; it now exits on its verdict.
- The recovery publish after the failed release built no Lambda layer, so the first deploy ran
  new code on the old layer. Fixed in the same workflow; see
  [the Effect 4 plan's §5](../effect-v4-migration.md#5-what-the-port-found).

## NU3 Close the loose ends

- Mark [EVQ2](../../analysis/effect-v4-migration.md#6-open-questions) in the Effect 4 analysis
  answered, and drop the Node bullet from
  [the Effect 4 plan's §2](../effect-v4-migration.md#2-behavior-changes-that-do-not-show-up-as-compile-errors).

**Result:** done.

## NU4 Done

`git mv` this plan to `docs/plans/done/` in the commit that finishes [NU3](#nu3-close-the-loose-ends).
