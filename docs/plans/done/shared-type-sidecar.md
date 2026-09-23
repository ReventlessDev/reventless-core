# Plan: a module of shared schema types gets a sidecar of its own

**Status:** ✅ Done — 2026-09-24. T1 and T2 built; T3 ships with the next PPX release.<br/>
**Touches:** `packages/reventless-ppx` only (`src/ppx/SidecarEmit.ml`, `src/ppx/ReventlessPpx.ml`,
`src/test_sidecar/`, `test/run.sh`), the root `.gitignore`, and
`docs/guides/reverse-codegen-pipeline.md`.

## Goal

A plain module that declares `@schema` types for components to share gets a
`<Stem>.types.json` sidecar. It holds each of the module's `@schema` types in the encoding the
`.model.json` sidecar already uses. A reader can then resolve a field typed `DeliveryOption.t`
to its variant or record without parsing ReScript. Nothing in the module has to say so: no
attribute, no mode.

## Why

A type that more than one component uses is best declared once, in a module of its own:

```rescript
// src/DeliveryOption.res
@schema
type t =
  | Standard
  | Express
  | Pickup({storeId: string})
```

A spec that uses it writes `delivery: DeliveryOption.t`, and its `.model.json` records the field
as `{"kind": "custom", "name": "DeliveryOption.t"}`. That is all a reader learns. The spec's
**own** `@schema` types reach its sidecar with their shape (`type_entry` in `SidecarEmit.ml`
writes every top-level `@schema` type of an `@@reventless.spec` file). A module that is not a
spec gets no sidecar, so a type declared there reaches no reader. Tools that offer a field's
choices, or build a sample value for it, can do so for a spec's local variant but not for the
same variant once it is shared.

## Scope

**In:** the rule that selects a module, the `.types.json` sidecar, their tests, the `.gitignore`
entry, and the guide.

**Out:**

- **Runtime meaning.** Nothing the compiler or the framework sees changes. The PPX only writes
  a file beside the module, and only when asked to.
- **Identity modules** (`include Reventless.Id.Make(...)`). They declare no `@schema` type of
  their own, so the rule does not select them, and they stay recognised by name
  (`Util.identity_module`).
- **Positional payloads.** `Foo(string)` is recorded as payloadless in `.model.json` today
  (`fields_of_args` keeps inline-record payloads only), and the same encoding is reused
  unchanged. Inline-record payloads (`Pickup({storeId: string})`) are recorded with their
  fields, as they already are.
- **Registering app types with `Semantic`.** See D4.

## Design

### Which modules

A module gets a `.types.json` when all of these hold:

- `REVENTLESS_EMIT_SIDECAR` is set, as for every other sidecar;
- it carries no `@@reventless.*` mode attribute (spec, behavior, projection, automation,
  translation, mappings, extension, task), no `@@reventless.gwt` or `@@reventless.examples`,
  and is not a GWT file by name (`looks_like_gwt_file`). Each of those already has its own
  sidecar or none, and none of them is a module of shared types;
- it declares at least one top-level `@schema` type.

A module is selected by what it is, the way an identity module is recognised by its name and
not by an annotation. So a shared type written by hand, or before this existed, is read like
one a tool wrote.

A spec is never selected, and needs nothing new: its own local types already reach its
`.model.json`, since `type_entry` writes every top-level `@schema` type of a spec file. A reader
resolves a spec's local type used elsewhere (`RegisterOrder.shippingMethod`) there, as
`<spec stem>.<typeName>`, just as it resolves a shared one in a `.types.json`.

### The sidecar

`<Stem>.types.json`, beside the `.res`:

```json
{
  "module": "DeliveryOption",
  "file": "plugin/src/DeliveryOption.res",
  "types": [
    {
      "typeName": "t",
      "shape": "variant",
      "elements": [
        {"name": "Standard", "payloadless": true, "fields": []},
        {"name": "Express", "payloadless": true, "fields": []},
        {"name": "Pickup", "payloadless": false, "fields": [{"name": "storeId", "kind": {"kind": "string"}, "...": "..."}]}
      ]
    }
  ]
}
```

- **`module`** is the file stem, which is how other modules name it. A reader resolves the
  `custom` kind `DeliveryOption.t` as the entry `typeName: "t"` in the sidecar whose `module`
  is `DeliveryOption`.
- **`types`** are produced by the existing `type_entry` over every top-level `@schema` type in
  the module. The usual shared module declares exactly one, `t`, but one that declares two
  related types needs no special case: a reader forms `<module>.<typeName>` for each.
- **`file`** is repo-relative, as in the other sidecars.
- The suffix is deliberately **not** `.model.json`. Readers treat every `.model.json` as a
  component's spec and derive a kind and a chapter from its path. A shared type is not a
  component.

Written best-effort like the other sidecars: a failed write is logged, never fatal.

## Phases

### T1 — The rule and the sidecar

`types_sidecar_path` and `maybe_emit_types` in `SidecarEmit.ml`, reusing `type_entry`, and the
check in `ReventlessPpx.transform` that selects a module by the rule above.

Tests in `src/test_sidecar/`:

- a payloadless variant, a variant with an inline-record payload, and a record, each as `t`;
- a module declaring two `@schema` types;
- no `.types.json` without `REVENTLESS_EMIT_SIDECAR`, for a module with no `@schema` type (an
  identity module among them), for a spec, for a behavior file, for a GWT file and for an
  examples file;
- the module compiles to the same output with the variable set and unset.

### T2 — Documentation and ignore rules

`*.types.json` in the root `.gitignore` beside the other sidecars. In
`docs/guides/reverse-codegen-pipeline.md`, a line in the pipeline sketch and in the list of
sidecars, with the rule that selects a module.

### T3 — Release

Released with the next PPX version.

## Decisions

| # | Decision | Leaning |
|---|---|---|
| **D1** | Select a module by an attribute, or by what it is? | **By what it is**: a plain module with a `@schema` type. An attribute is one more thing to write, and forgetting it fails silently, since the type then reaches no reader. The cost of the rule is a sidecar for a helper module that nobody reads, which is written only on request and ignored by git. And a helper's type used by a spec is exactly what a reader wants to resolve |
| **D2** | A new suffix, or `.model.json`? | **`.types.json`.** Every existing reader of `.model.json` reads it as a component |
| **D3** | Only `t`, or every `@schema` type? | **Every one**, keyed by `typeName`. It costs nothing, and a module that shares two related types is ordinary |
| **D4** | Register app types in `Semantic` instead? | **No.** `Semantic.valueTypes` is a static list of the framework's own value types. App types exist per plugin and are known only when the plugin is built. A payloadless variant is close to a `Codes` value type and a record to `Parts`, but there is no case for a variant whose choices carry data, and the registry is not where an app's vocabulary belongs |

## Acceptance

Built with `REVENTLESS_EMIT_SIDECAR=1`, a plugin with `src/DeliveryOption.res` as above gets
`src/DeliveryOption.types.json` with `module: "DeliveryOption"` and one variant entry `t`, whose
`Pickup` element carries `storeId`. A record module gets `shape: "record"`. An identity module,
a spec and a behavior file get no `.types.json`. Without the variable nothing is written, and
the compiled output is the same either way.

## Outcome

- The dispatcher's check is `ReventlessPpx.is_shared_types_module`; the sidecar is
  `SidecarEmit.types_fragment_json` / `maybe_emit_types`, reusing `type_entry`.
- `SidecarEmit.is_enabled` now reads the variable on each call instead of caching it, so a
  test can prove "nothing without the variable" and "a file with it" in one process. A build
  reads it once per file either way.
- Covered twice: `test_sidecar` drives `ReventlessPpx.transform` over files in a temp dir
  (every case in T1, and the pretty-printed output compared with the variable set and unset),
  and `test/run.sh` compiles `DeliveryOption.res` from real ReScript beside an examples file and
  a GWT file that each declare a `@schema` type and get no `.types.json`.
