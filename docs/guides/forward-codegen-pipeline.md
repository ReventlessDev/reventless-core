# Forward Codegen Pipeline

> **Not part of the published documentation site.** The tooling described here
> lives outside `reventless-core` and is not published to a registry, so this
> guide is kept in-tree for maintainers rather than on docs.reventless.dev.

This guide covers the **forward leg** of the Event Model ↔ code roundtrip — turning an upstream Event Modeling artifact (Event Modeling JSON today; prooph-board / YAML / Reventless-native later) into the Spec + GWT files that compose a Reventless plugin.

The pipeline is owned by the `@reventlessdev/reventless-codegen` package. The inverse direction (code → model) is the [Reverse Codegen Pipeline](./reverse-codegen-pipeline.md). AI synthesis of skeleton bodies is a separate, planned capability and is not described here.

---

## TL;DR

```bash
# Validate an Event Modeling JSON document
pnpm exec node reventless/codegen/run-codegen.mjs validate \
  --in path/to/model.json --plugin-name Catalog

# Run a full forward pass — writes Spec / GWT / Skeleton / sync-base
pnpm exec node reventless/codegen/run-codegen.mjs forward \
  --in path/to/model.json --plugin-name Catalog --out path/to/plugin
```

The output directory ends up with:

```
plugin/
├── .reventless/sync-base/<slice-id>.json   # one per slice — the merge base for the reverse pass
├── src/<Chapter>/<SliceKindFolder>/<Stem>.res            # Spec  (always overwritten)
├── src/<Chapter>/<SliceKindFolder>/<Stem>_<Kind>.res     # Skeleton (only on first emission)
└── tests/<Chapter>/<SliceKindFolder>/<Stem>_GWT.res      # GWT   (always overwritten)
```

---

## Canonical model

Every adapter targets one in-memory shape: [`Model.t`](https://github.com/ReventlessDev/reventless-core/blob/alpha/reventless/codegen/src/Model.res). It carries slices, aggregates, read models, and structural chapters; each entity has a stable `id` for rename-survival across roundtrips. The same `@schema`-derived JSON codec writes the sync-base snapshots, so the on-disk format is human-diffable in PRs.

Structural chapters in `slice.context` (e.g. `"Catalog.Product"`) become subfolder names — the first segment is the plugin, the rest is the chapter folder under `src/` and `tests/`.

---

## Provenance headers

Every file the pipeline emits starts with one comment line:

```
// ROUNDTRIP from event-model://<adapter>/<entityKind>/<id>
```

The reverse pass keys off this header to locate the upstream entity. If the header is removed, the file becomes hand-authored from the codegen's perspective — not a corruption, just an exit from the roundtrip.

---

## Skeletons are emitted once

`X_<Kind>.res` (the Implementation skeleton) is written **only when no implementation file exists**. Re-running `forward` against a model change preserves the file with a "this skeleton was preserved" line in the report. The intent: once a developer (or a future AI synthesis step) has filled in the body, model changes should never silently overwrite that work.

If you want to re-generate a skeleton, delete the file and re-run.

---

## Sync base

After every successful forward pass the pipeline writes a per-slice JSON snapshot at `<plugin>/.reventless/sync-base/<id>.json`. This is the merge base for the reverse pass — it captures the canonical shape exactly, with no Reventless-specific data lost. Snapshots are pretty-printed with 2-space indentation and a trailing newline so PR diffs stay reviewable.

Check `.reventless/` into the plugin repo. Nothing under it should be `.gitignore`d.

---

## `_Fixtures.res` and `_ExtraGWT.res`

The pipeline never emits, parses, or modifies files matching these patterns:

- **`<Stem>_Fixtures.res`** — hand-authored shared test data (auto-opened by the `@@reventless.gwt` PPX into the companion GWT file)
- **`<Stem>_ExtraGWT.res`** — hand-authored scenarios that should *not* round-trip back to the upstream model

Use `_ExtraGWT.res` for any scenario that uses fixture references, helper calls, or computed values — the reverse pass only round-trips inline-literal scenarios.

---

## Diagnostics

`validate` parses the input and exits non-zero on structural errors. Per-field warnings (unresolved `Custom` types, missing examples, slice straddling plugins) are printed to stderr but do not fail the run — review them when extending or migrating models.

The `forward` subcommand surfaces the same warnings before writing files; if any structural error is reported, no files are written.

---

## Adapters

Currently only the **Event Modeling** adapter (`--adapter eventmodeling`) ships. The `Adapter.T` interface is in place for future adapters (prooph-board, YAML DSL, Reventless-native canonical JSON), each of which is a self-contained follow-up.

---

## References

- [`docs/analysis/spec-implementation-split.md`](https://github.com/ReventlessDev/reventless-core/blob/alpha/docs/analysis/spec-implementation-split.md) — Spec-First file boundaries that this pipeline emits into
- [`docs/analysis/given-when-then-specifications.md`](https://github.com/ReventlessDev/reventless-core/blob/alpha/docs/analysis/given-when-then-specifications.md) — GWT methodology that the emitter targets
