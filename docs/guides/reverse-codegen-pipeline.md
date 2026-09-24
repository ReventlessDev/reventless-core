# Reverse Codegen Pipeline

> **Not part of the published documentation site.** The tooling described here
> lives outside `reventless-core` and is not published to a registry, so this
> guide is kept in-tree for maintainers rather than on docs.reventless.dev.

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
@@reventless.examples files ─────────────────► <Stem>.examples.json (PPX)
modules of shared @schema types ─────────────► <Stem>.types.json   (PPX)
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
- `<Stem>.gwt.json` — for every `@@reventless.gwt` file: per scenario its id (`scenarioId`), title, and given/when/then steps with their example values.
- `<Stem>.examples.json` — for every `@@reventless.examples` file (a module of named example values): its `module` (the file stem), `file`, and per top-level `let` of a single name its `name`, `type` (the annotation as written, `""` when there is none), `kind` (as for a spec field; `custom Unknown` when unannotated), `line`, and `value`. The attribute selects no mode; the PPX removes it and compiles the file as written.
- `<Stem>.types.json` — for every plain module that declares `@schema` types for components to share (`DeliveryOption.t`): its `module` (the file stem), `file`, and `types`, each top-level `@schema` type in the `.model.json` encoding (`typeName`, `shape`, `elements`). A spec field typed `DeliveryOption.t` reads `{"kind": "custom", "name": "DeliveryOption.t"}`; a reader resolves it as the entry `typeName: "t"` of the sidecar whose `module` is `DeliveryOption`. A module is selected by what it is, with no attribute: it carries no `@@reventless.*` mode (spec, behavior, projection, automation, translation, mappings, extension, task), no `@@reventless.gwt` or `@@reventless.examples`, is not a GWT file by name, and declares at least one top-level `@schema` type. So an identity module (`include Reventless.Id.Make(...)`) gets none. A spec's own types need no such file: they are already in its `.model.json`, where a reader resolves `RegisterOrder.shippingMethod` the same way.

An example value is a literal where the source writes one (`string`, `int`, `float`, `bool`, `null` for `None`, `enum` for a payload-less constructor, a `string` with its `constructor` for a typed id like `oid("o1")`, `list`, `record`). `Some(x)` is `x`'s value. A named value (`dockLine`, `OrderingExamples.dockLine`) is `{"kind": "ref", "name": …}`, recorded as written and not resolved. Any other expression (`eur(4500.0)`) is `{"kind": "code", "value": …}`, its exact source text cut from the file; only when that text cannot be had is the value left out.

A scenario's id comes from a `// scenario-id: <id>` comment on the line above its `test(`. The older spelling `// spec-id: <id>` is still read, and always will be. A marker belongs only to the test directly below it: a test with no marker of its own gets the id `""`, even when a marked test comes before it. The sidecar also repeats the id under `specId`, for codegen releases that read only that key; that duplicate will be dropped once the codegen reads `scenarioId`.

Sidecars are **derived artifacts**, emitted **only** when `REVENTLESS_EMIT_SIDECAR=1` — which `export` sets before it builds. Ordinary `rescript build` writes nothing new. They are git-ignored (`*.model.json` / `*.gwt.json` / `*.examples.json` / `*.types.json` / `*.wiring.json`) and never hand-edited: `export` does a clean rebuild first so they cannot lag source.

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

**Nested records.** A `@schema` record that a command / event / consumedEvent field holds (as `T`, `option<T>` or `array<T>`) is tagged at runtime by `DcbTag.nestedRecordTags`, keyed by the nested field's own name. Only `@ref` puts tag metadata on a record's fields, so the sidecar reports such a field as `customKey` when it carries `@ref` (keyed like the runtime: `@dcbTag("k")`, else the identity's key, else the field name), `suppressed` when `@ref` sits beside `@noDcbTag`, and `noTag` otherwise. `PlaceOrder`'s `lineItems[].productId` is a `productId` tag; `OrderPlaced`'s `lines[].productId`, without `@ref`, is not.

**Reference targets.** A field carrying `@ref("Entity")` or `@ref("Plugin.Entity")` also gets `"ref": {"entity": "Entity", "plugin": null | "Plugin"}` in the `.model.json` sidecar. Fields without `@ref` have no `ref` key.

**Field annotations.** A field's `annotations` lists what its source says, in order. An annotation without an argument is its name (`"owner"`). One with an argument is `{"name": "storageRef", "args": "\"Catalog.productImages\""}`, where `args` is the source text between the parentheses, as written, quotes included: a reader writes it back as it came, and parses it only where it needs the value (as `ref` does for `@ref`). The parser's own hints (`res.optional`, `res.doc`, …) are always names. The `.types.json` sidecar writes its fields the same way.

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
