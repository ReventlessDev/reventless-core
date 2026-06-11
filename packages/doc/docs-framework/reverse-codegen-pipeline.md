# Reverse Codegen Pipeline

This guide covers the **reverse leg** of the Event Model ↔ code roundtrip — reading a Reventless plugin's ReScript source back into an Event Modeling JSON model. It is the exact inverse of the [Forward Codegen Pipeline](./forward-codegen-pipeline.md): where `forward` turns a model into Spec + GWT files, `export` turns those files back into a model. Together they close the loop, so a model can be edited as code or as a diagram and kept in sync.

The pipeline is owned by the `@reventlessdev/reventless-codegen` package. AI synthesis of skeleton bodies is a separate, planned capability and is not described here.

## TL;DR

```bash
# Read a plugin's source back into an Event Modeling JSON model
node run-codegen.mjs export --in <plugin-dir> --adapter eventmodeling --out model.json
```

`export` builds the plugin (to refresh sidecars), assembles the canonical model from those sidecars, merges it against the sync base, and renders Event Modeling JSON.

## How it works

The compiler is the parser. Rather than re-parse `.res`, the **`reventless-ppx`** pass — which already walks the typed AST of every Spec / GWT file — emits a structured JSON **sidecar** per component, and the reverse pass stitches the sidecars into the canonical `Model.t`, then renders Event Modeling JSON.

```
                         REVENTLESS_EMIT_SIDECAR=1
plugin/src/**/*.res ──── rescript build ────► <Stem>.model.json   (PPX)
plugin/tests/**/*_GWT.res ───────────────────► <Stem>.gwt.json     (PPX)
                                   │
                                   ▼
                  Assemble    sidecars + provenance headers → Model.t
                                   │
                                   ▼
                  Merge       code-authoritative merge vs sync base
                                   │
                                   ▼
                  EventModelingExport → model.json
```

### Sidecars

- `<Stem>.model.json` — for every `@@reventless.spec` file: each `@schema type` (command / event / consumedEvent / error / state) as a list of elements whose fields carry name, kind, identity flags, and the resolved DCB-tag **`dcbRole`**.
- `<Stem>.gwt.json` — for every `@@reventless.gwt` file: per scenario the `spec-id`, title, and given/when/then steps with literal example values.

Sidecars are **derived artifacts**, emitted **only** when `REVENTLESS_EMIT_SIDECAR=1` — which `export` sets before it builds. Ordinary `rescript build` writes nothing new. They are git-ignored (`*.model.json` / `*.gwt.json` / `*.wiring.json`) and never hand-edited: `export` does a clean rebuild first so they cannot lag source.

## DCB-tag fidelity (`dcbRole`)

Event Modeling JSON has a single identity signal (`idAttribute`); Reventless DCB tagging is richer. The canonical model carries a four-way `dcbRole` so intent survives the roundtrip:

| `dcbRole`    | Source annotation | Event Modeling JSON | Notes                                          |
| ------------ | ----------------- | ------------------- | ---------------------------------------------- |
| `Partition`  | `@partitionTag`   | `idAttribute: true` | the DCB consistency key                        |
| `Suppressed` | `@noDcbTag`       | absent              | an `*Id`-shaped field intentionally untagged   |
| `CustomKey`  | `@dcbTag("k")`    | absent              | custom tag key                                 |
| `AutoString` | _(none — auto)_   | absent              | `xxxId: string`, auto-tagged by the PPX        |
| `NoTag`      | _(none)_          | absent              | ordinary payload                               |

`@partitionTag` / `@noDcbTag` / `@dcbTag` survive `code → JSON → code`; plain `*Id` fields stay auto-tagged. The auto roles emit no annotation, so the forward emitter stays silent for them.

## Merge authority

`export` is a three-way merge against the [sync base](./forward-codegen-pipeline.md#sync-base) (`.reventless/sync-base/<id>.json`):

- **Code is authoritative for structure** — names, fields, `dcbRole`, kinds, connections, specifications.
- Entities are matched by stable `id` (the provenance header, or a deterministic minted id for header-less files).
- **Additions** (in code, new) are included; **deletions** (in the sync base, gone from code) are dropped and reported. `export` exits non-zero on deletions unless `--allow-conflicts`.

After a successful `export` (not `--check`), the merged model is **re-snapshotted to the sync base**, so it always reflects the current code.

### The sync base as fidelity carrier

Some information lives in code (or on the diagram) but has no home on the *other* side of the boundary. The sync base carries it across so a full roundtrip does not silently drop it:

- **Visual layer** — `status`, `index` (timeline position), `screens`, `actors`, `aggregates`, `screenImages`. Event Modeling JSON carries these; ReScript cannot express them. `import` captures them opaquely on `slice.passthrough`, the merge carries them forward onto the code model (which has none), and `export` splices them back in at the JSON level. So **`JSON → code → JSON` preserves the visual layer**, and re-export is byte-stable.
- **`consumedEvent` narrowing** — a payload-less (`| OrderShipped`) or partial-projection consumer. Event Modeling JSON events are always full-shape, so a `JSON → code` import would re-widen them. The sync base holds the true `partial` flag; the forward pass restores it before emitting, so a narrowed consumer survives `code → JSON → code` instead of widening to a full payload.

## Flags

| Flag                | Effect                                                                                                       |
| ------------------- | ------------------------------------------------------------------------------------------------------------ |
| `--check`           | Assemble + merge but diff against the existing `--out` instead of writing (CI drift guard); non-zero on drift. Does not write the sync base. |
| `--allow-conflicts` | Export even when the sync base has entities absent from code (deletions).                                     |
| `--no-build`        | Skip the sidecar-refresh build (sidecars already current).                                                    |

## What does and does not round-trip

Round-trips:

- command / event / error / state structure, field kinds, and `dcbRole`;
- **cross-slice event consumption** — a read model's consumed events export as its `INBOUND` dependency graph (resolved to the producing event) and reimport to the same `consumedEvents`, so a read model is never link-less;
- **the visual layer** (`status` / `index` / `screens` / `actors` / `aggregates` / `screenImages`) via `slice.passthrough` (see _fidelity carrier_ above);
- **payload-less / partial consumed events** via the sync base (above);
- inline-literal GWT scenarios.

Does **not** round-trip: implementation _logic_ (`decide` / `evolve` / `project` / `translate` bodies — not model-representable), Stream-variant / Aggregate-vs-DCB identity (chosen on import), and GWT scenarios using fixtures / computed args — keep those in `<Stem>_ExtraGWT.res` (see the [forward guide](./forward-codegen-pipeline.md#_fixturesres-and-_extragwtres)).
