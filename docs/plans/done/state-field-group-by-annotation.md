# `@groupBy` state-field annotation → `x-reventless-group-by`

**Status:** PLAN 2026-07-10. Small, framework-neutral core annotation. The **consumer is already
built**: reventless-ui's AutoListView now renders a read model's rows in sections keyed on the
field annotated `x-reventless-group-by` (see reventless-ui `docs/plans/autoui-group-list-by-field.md`,
implemented + unit-tested). This plan is the core emission side that activates it.

**First use:** annotate the lifecycle Plugins read model's `kind` field so the admin Plugins view
(`Platform_Plugins`) sections `PlatformInfrastructure` plugins (the inspector `Platform` row,
Console, …) away from the domain plugins — the UI-repo step 7 of
`platform-infrastructure-in-plugin-list.md`.

## Shape — mirror `@status` exactly

`@status` is the precedent: a single-field state annotation carried as
`stateAnnotationSpec.status: option<string>`, emitted by the PPX, consumed downstream. `@groupBy`
is the same shape (at most one group-key field per read model).

1. **`reventless-spec …/components/StateAnnotations.res`** — add
   `groupBy: option<string>` to `stateAnnotationSpec` (sibling to `status`), with the same
   "PPX errors on duplicate `@groupBy` in one record" rule. Document it.
2. **PPX (`packages/reventless-ppx`)** — parse a `@groupBy` field attribute on `@schema type
   state` records and populate `stateAnnotationSpec.groupBy`, mirroring the `@status` handling
   (same duplicate-detection + error path). This is the only non-trivial step; scope it against
   the existing `@status` parse site.
3. **`reventless-core …/components/Api/SuryToJsonSchema.res`** — in `deriveObjectSchema`, emit
   `obj->Dict.set("x-reventless-group-by", JSON.Encode.bool(true))` for the field named by
   `spec.groupBy` (sibling to the `spec.summary->Array.includes(fieldName)` branch at line ~44).
4. **`reventless-core …/plugin/lifecycle/PluginsReadModelSpec.res`** — annotate the `kind` field
   `@groupBy`. (`kind` already exists on the state as of alpha.148/149 — this only tags it.)
5. **Tests** — a `SuryToJsonSchema` case asserting a `@groupBy`-annotated field emits
   `x-reventless-group-by: true` and others don't; a PPX/spec case asserting `groupBy` is
   populated (and that duplicates error). Mirror the `@status`/`summary` test siblings.

## Notes / non-goals

- **Enum ordering:** the UI orders sections by the group field's `enum` declaration order (it
  already reads `enum` off the property schema). So the *display* order of the Plugins sections is
  the declaration order of `pluginKind` (`Domain | PlatformInfrastructure | Commercial |
  Marketplace`). If "infrastructure last" is wanted, reorder that enum — no UI change needed.
- **No runtime/data change.** This only stamps a schema extension; projections and resolvers are
  untouched.

## Consumer / deploy chain (outside core)

- reventless-ui: **done** (AutoListView grouping + `SchemaAnnotations.groupBy`/`groupByField`/
  `fieldEnum` + `AutoGroupRows`, tests green).
- business: bump reventless-core + reventless-ui once this ships; **redeploy platform-aws on the
  new core** (the `Platform_Plugins` rows + AutoUI field definitions are served there, and also
  need core with `kind` populated on the row — tracked in business
  `platform-row-in-plugin-list-downstream.md`).

## Acceptance

- A `@groupBy`-annotated state field emits `x-reventless-group-by: true` in the read model's JSON
  schema; duplicate `@groupBy` in one record is a PPX error; no other schema changes.
- The Plugins read model schema carries the annotation on `kind`; downstream (reventless-ui) then
  sections the admin Plugins view by kind with zero further UI work.
