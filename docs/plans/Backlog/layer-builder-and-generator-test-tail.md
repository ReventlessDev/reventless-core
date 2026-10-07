# Plan: the layer builder's failure paths and the plugin generator's file reading get tests

**Date:** 2026-10-07<br/>
**Status:** Backlog — extracted from [../done/quality-performance-hardening.md](../done/quality-performance-hardening.md) (its items D1 and D2) when it closed. Optional: the fixes these tests would pin already shipped and nothing is known broken; this is guarding against regressions.<br/>
**Relates to:** [optimize-lambda-layer-size.md](optimize-lambda-layer-size.md) — records layer zip sizes by hand; the size guard below would turn that into a check.

---

## In plain words

The hardening plan fixed several bugs in two build-time tools — the Lambda
layer builder (`reventless/layer-builder`, private) and the plugin generator
(`generate-plugin`, in `reventless/spec/src/generator/`) — and gave both a test
harness. The parts that read or write files were left without tests, because
they need fixture directories rather than plain values. Those are what is left.

## Layer builder (`reventless/layer-builder`)

Today `tests/` holds only `DependencyBundler_FilterTest` (the pure keep/strip
classification). Still untested, checked 2026-10-07:

- **A failed post-process step fails the build.** `DependencyBundler.doPostProcessing`
  returns `false` and the build ends in `panic("layer build: one or more
  post-processing steps failed")`. A test with a step that throws, run over a
  temp directory, pins that a failure is never shipped as a green layer.
- **The "requires rescript!" guard fires.** It reads
  `tree.children.get("rescript")` directly now; a fixture tree that depends on
  rescript without providing it should panic with that message.
- **A size guard on the zip** (`Packaging_AwsLambdaLayer.res`): fail, or at least
  warn, past a stated ceiling, so a regression that bundles deploy-time code
  shows up in CI rather than in a Lambda limit error.
- **A smoke import of the layer's entry points** after a build.
- The `DependentExcluded` branch of the filter (a walk over `edgesIn`).

## Plugin generator (`reventless/spec/src/generator`)

- **`Pairing.extractTargetName`** still finds `let targetName = ` by scanning
  source lines and taking the text between the first and last `"` on the line.
  A trailing comment containing a quote corrupts the name, a type-annotated
  declaration (`let targetName: option<string> = …`) is missed, and a read error
  is swallowed as `None`. Harden it (or read the value another way) and add
  fixture cases for each.
- **A whole-generator test**: write a small plugin `src/` into a temp directory,
  run `Discovery` → `Pairing.resolve` → `Codegen`, and compare the emitted
  `Plugin.res` with a golden file. `DiscoveryTest` already uses `mkdtempSync` for
  `scanIdentities`, so the pattern is in place.

## Core regression test

- **Optimised projection actions equal unoptimised ones.** The off-by-one in
  `Projection.optimizeActions` was fixed with two example cases
  (`reventless/core/tests/projection/ProjectionOptimizeTest.res`). The general
  property — applying `optimizeActions(actions)` leaves the store exactly as
  applying `actions` one by one — is still untested; a generated-sequence test
  over `Set`/`Update`/`Delete` would cover it.

The rest of the original regression list is covered in this repo now, or
belongs to the test runner, which moved to the `reventless-dev` package in
reventless-tools.

## Done when

Each bullet above has a test that fails when the behaviour it names regresses,
and they all run under root `pnpm test`. Note that root `jest.config.js` has
**no `reventless-layer-builder` project** (checked 2026-10-07), so even the
existing `DependencyBundler_FilterTest` runs only from the package directory and
never in CI. Adding that project — and with it the check in
`scripts/check-jest-projects.mjs` that it finds at least one suite — is the
first step.
