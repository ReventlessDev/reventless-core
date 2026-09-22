# Plan: the GWT scenario marker says `scenario-id`, and belongs to one test

**Status:** ✅ C1–C3 shipped — released 2026-09-22 in ppx 1.0.0-alpha.84 (with spec
3.0.0-alpha.142). The PPX reads both marker spellings, writes `scenarioId` and `specId`, and
gives an id only to the test directly below its marker; the guide says so. C4 (stop writing
`specId`) is still pending: it waits for the companion plan's Phase 5.<br/>
**Touches:** `packages/reventless-ppx` only (`src/ppx/SidecarEmit.ml`, `src/test_sidecar/`), and
`docs/guides/reverse-codegen-pipeline.md`.<br/>
**Companion:** reventless-tools `docs/plans/scenario-naming-and-the-event-model-boundary.md`,
which renames "specification" to "scenario" throughout the codegen and the VS Code extension.
Its Phase 5 switches the marker the codegen writes, and it must not start before this plan's
release. Both are sequenced by reventless-tools `docs/plans/scenario-authoring-orchestrator.md`,
which ships this plan in one core release with `docs/plans/semantic-value-types.md`.

## Goal

A GWT scenario's identity comment reads `// scenario-id: <id>`. The PPX reads that and the
old `// spec-id: <id>`, and writes the id to the `.gwt.json` sidecar under a key named for what
it is. Each id belongs to the one test directly below its comment, and never to a test further
down.

## Why

**The word.** In this codebase "spec" names a slice's definition file (`@@reventless.spec`),
while `spec-id` names one scenario in a `@@reventless.gwt` file. The companion plan removes the
second meaning everywhere outside Event Model import and export. The marker is written by the
codegen, but core's PPX reads it, so the new spelling cannot be written until the PPX reads it.
Otherwise every export would silently lose its scenario ids.

**A defect found while grounding this.** `spec_id_for` gives a test the id of the *nearest
preceding* marker, however far above it is (`SidecarEmit.ml`; its test asserts that line 10
gets the marker on line 7 when the markers sit on lines 3, 7 and 12). A test with no marker of
its own therefore inherits the id of whichever marked test comes before it:

```rescript
// spec-id: 1111
test("written by the form", () => …)

test("written by hand afterwards", () => …)   // sidecar: specId "1111" as well
```

Two scenarios with one id then reach the reverse pass, which keys renames and merges off that
id. This is reachable now: the codegen's `scenario-write` appends form-written tests at the end
of a hand-written file, and anything added below them later inherits their id. The VS Code
extension already reads a marker only when the `test(` follows it directly, so the two readers
disagree about the same file.

## Scope

**In:** the PPX's marker reading, the id's key in the `.gwt.json` sidecar, the id-to-test
assignment, the PPX's own internal names for these, and the guide that documents the sidecar.

**Out:**
- The `.model.json` sidecar. Its `specName` names the spec file, and "spec" is right there.
- The `.gwt.json` sidecar's top-level `specName` (the `describe` title). It names the spec
  under test, not a scenario.
- Everything in reventless-tools, which is the companion plan.

## Phases

### C1 — Read both markers, write both keys

- `read_spec_ids` becomes `read_scenario_ids`. It accepts a line that starts with
  `// scenario-id:` or `// spec-id:` after trimming, and returns `(line, id)` as today.
- `gwt_fragment_json` writes each scenario's id under **`scenarioId`**, and also under
  `specId` while released codegen still reads only `specId`. Dropping `specId` is C4 and is
  gated on the companion plan's release.
- `test_sidecar.ml`:
  - a file mixing both marker spellings yields both ids;
  - the emitted JSON carries `scenarioId` and `specId` with the same value.

### C2 — An id belongs to the test directly below it

- `spec_id_for` becomes `scenario_id_for`. A marker on line `n` applies to the test starting
  on line `L` only when **no other test starts between `n` and `L`**. Otherwise the test has no
  id (`""`), exactly like a test with no marker at all.
- The test locations are already collected in `gwt_fragment_json`, so this needs no new parse:
  pass the sorted test start lines alongside the marker list.
- `test_sidecar.ml`:
  - The existing nearest-preceding assertion becomes: markers on 3 and 7 with tests on 4, 8
    and 10 give `a`, `b` and no id.
  - A form-written test followed by a hand-written one gives the second no id.
- **Behaviour change, stated in the changelog:** a test that relied on inheriting an earlier
  marker's id loses it. No generated file relies on that, because the forward emitter writes
  a marker directly above every test it emits.

### C3 — Release

- Follows the PPX release procedure: build, stage the binary locally, remove every workspace
  `lib/` (never `rescript clean` over the examples), run `packages/reventless-ppx/test/run.sh`
  (it is not in the root chain), and ship C1 and C2 as one commit. CI publishes the binary and
  resolves the version; do not bump it by hand.
- `docs/guides/reverse-codegen-pipeline.md`:
  - it describes `// scenario-id:`, and says `// spec-id:` is still read;
  - it names the sidecar key `scenarioId`;
  - it states that a marker belongs only to the test directly below it.
- **Exit:** the published PPX reads both spellings, writes both keys, and assigns ids
  per test. The companion plan's Phase 5 may start.

### C4 — Stop writing `specId` (later)

- Once the companion plan's Phase 5 is released, the codegen reads `scenarioId` and falls back
  to `specId` itself. The PPX then writes `scenarioId` alone.
- Reading `// spec-id:` stays **permanently**. It is one string comparison, and generated apps
  carry the old spelling until their next forward pass.

## Verification

- `packages/reventless-ppx/test/run.sh` passes with the new assertions.
- On an example with no markers (none of the examples have any today), the sidecars show
  every `scenarioId` as `""`, as `specId` was before.
- A scratch GWT file with a form-written test followed by a hand-written one:
  - the sidecar gives the first its id and the second none;
  - with the marker spelled either way, the ids come out the same.

## Risks

- **A consumer pairs the new PPX with a codegen that reads only `specId`.** C1 writes both keys
  for exactly this; C4 waits for the companion release.
- **C2 changes an id a user depended on.** Only a hand-written test placed below a marked one
  loses an id, and that id was never its own: it belonged to the test above.
