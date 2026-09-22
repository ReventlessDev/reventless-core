# Plan: the model sidecar keeps reference targets and nested DCB tags

**Status:** ✅ Done — 2026-09-22. S1 built and released in the PPX 1.0.0-alpha.86 (S2).<br/>
**Touches:** `packages/reventless-ppx` only (`src/ppx/SidecarEmit.ml`, `src/test_sidecar/`) and
`docs/guides/reverse-codegen-pipeline.md`.<br/>
**Companion:** reventless-tools `docs/plans/scenario-example-data.md`, phase E7d, where the
scenario form offers the ids a scenario already holds for a reference field and notes a read
reference that Given does not supply.

## Goal

A reader of a `.model.json` sidecar can tell, for every field, which entity it references and
whether the decision queries it as a DCB tag, including a field of a record that a command or
event holds (`PlaceOrder`'s `lineItems[].productId`).

## Why

Two gaps in `SidecarEmit`, both found on `examples/online-shop-hybrid/ordering`'s `PlaceOrder`:

- **The reference target is dropped.** `attr_names` keeps an attribute's name only, so
  `@ref("AvailableProducts")` reaches the sidecar as `"ref"`. The PPX reads the target
  (`ReferenceInference.get_ref_target`) to emit `Reference.mark`; the sidecar leaves it out.
- **A nested record's fields are always `noTag`.** `dcb_role_json` gives the DCB context only to
  the `command` / `event` / … types themselves. At runtime `DcbTag.nestedRecordTags` extracts
  the tagged fields of a record that such a type holds, one level deep, keyed by the nested
  field's own name. So `lineItems[].productId` is a `productId` tag at runtime and `noTag` in
  the sidecar.

## S1 — Emit both

- **`ref` on a field.** A field carrying `@ref("Entity")` or `@ref("Plugin.Entity")` gets
  `"ref": {"entity": "Entity", "plugin": null | "Plugin"}` beside its `annotations`. A field
  without `@ref` gets no `ref` key, so every existing sidecar is unchanged. `annotations` keeps
  listing `"ref"`.
- **Nested DCB context.** A `@schema` record type in the same file is *nested* when a field of a
  DCB-context type holds it as `T`, `option<T>`, `array<T>` or `array<option<T>>`, the shapes
  `DcbTag.nestedRecordProperties` unwraps.
- **What a nested field reports** follows what the runtime tags, not the top-level rules. On a
  record type only `ReferenceInference` adds tag metadata; the auto-`*Id`, typed-id and explicit
  `@dcbTag` passes touch variant constructors only. So:
  - `@ref` without `@noDcbTag` → `customKey`, keyed by a `@dcbTag("k")` beside it, else the
    identity's conventional key, else a plural `*Ids` array's singular stem, else the field
    name;
  - `@ref` with `@noDcbTag` → `suppressed`;
  - anything else → `noTag`, as today.

  `orderLine.productId` (no `@ref`) in `OrderPlaced`'s `lines` therefore stays `noTag`, which is
  what the runtime extracts.
- A record held only by a non-DCB type (`state`, `error`) is not nested. A record held by both
  is nested.
- `test_sidecar.ml`: a nested record with a typed-id `@ref`, a string `@ref` with `@noDcbTag`, a
  plain typed id, and a `@ref("Catalog.Product")` plugin target; a record used only by `state`
  stays `noTag`; a top-level field without `@ref` has no `ref` key.
- `docs/guides/reverse-codegen-pipeline.md` names the `ref` key and the nested context.

## S2 — Release

The PPX release procedure, as in [gwt-sidecar-refs-and-examples.md](../gwt-sidecar-refs-and-examples.md)
R3. **Exit:** the published PPX writes `ref` and nested roles; the companion plan's E7d may rely
on them.

## Risks

- **A reader that decodes fields strictly.** The reverse-codegen reader (`Model.fieldFromJson`)
  ignores keys it does not know, and the key is absent unless `@ref` is present.
- **The sidecar drifts from the runtime.** The nested rule mirrors which passes transform record
  types. A pass that starts tagging record fields must update `dcb_role_json` in the same
  change; the sidecar test pins the current rule.
