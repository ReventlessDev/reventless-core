# Plan: `config.json` keys are checked across the repos, and local dev honours `viewModes`

**Date:** 2026-10-07<br/>
**Status:** Backlog — extracted from [../done/host-ui-shell-config-choices.md](../done/host-ui-shell-config-choices.md) when it closed. Optional follow-ups; none blocks a deployment. The escape hatch waits for a trigger (a mode core does not know).<br/>
**Relates to:** [../baked-manifest-without-host-ui-bundle.md](../baked-manifest-without-host-ui-bundle.md); reventless-ui's `autoui-deploy-verification.md` (the deployed browser checks).

---

## In plain words

`config.json` is the small file the host shell (the browser app) reads at start
to learn where its API is and which optional features to load. The deploy writes
it; the shell reads it. Three loose ends remain from making it something a
deployment can configure.

## 1. Local dev ignores `viewModes`

Since the parent closed, local dev *does* serve a composed `config.json`:
`reventless/local/src/ShellConfig.res` overlays the deployment's `shellConfig`
(and the computed `manifestUrl`) on the host-shell package's shipped file. But
`viewModes` is still dropped — `reventless/local/src/Platform.res`
(`hostUiBundleConfig`, the "Still ignored" comment) — so the map appears on a
deployed hybrid and not on a local one unless someone hand-edits the package's
`public/config.json`.

Done looks like: `ShellConfig` writes `viewModes` (and the flattened `mapStyle` /
`graphLayout`) the way `Util_ShellConfig.fields` does on AWS, ideally by sharing
the flattening rather than copying it; a `ShellConfigTest` case asserts it.

## 2. A contract test for the key names

The original finding was a key the shell reads and the deploy never wrote,
noticed only because a feature was missing. Writer (`Util_ShellConfig`, local
`ShellConfig`) and reader (the shell's `Config.res` in reventless-ui) still agree
by inspection only. A shared list of key names — published from one side and
asserted by the other's tests — would make a rename or a missing key fail a test
rather than a browser. Decide which side owns the list before building.

## 3. `Other(string)` on `viewMode` — only when needed

`ReventlessInfra.Platform.viewMode` (`reventless/infra/src/types/Platform.res`)
is a closed variant on purpose: a typo is a compile error, not a silently absent
feature. The first time the UI ships a mode core does not know, add an
`Other(string)` arm beside the typed ones. Adding it before then is just
`array<string>` with extra steps — so do nothing until that day.
