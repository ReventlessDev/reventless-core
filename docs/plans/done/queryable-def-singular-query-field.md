# Plan: Publish the singular query field name on `queryableDef`

## Status: ✅ Done

Landed as specified. Two notes on what differed from the file map:

- The "published value equals `Api_Naming`'s, including for an `-ies` name"
  assertion went to `PluginStructureTest` rather than
  `Platform_PluginStructuresApiTest`. The latter encodes hand-rolled fixtures, so
  comparing them against `Api_Naming` would assert only that the fixture's own
  literal was typed correctly; `PluginStructureTest` runs `Plugin_Structure.make`
  over real specs, which is where the derivation actually happens. A new
  `Categories` state-view fixture supplies the irregular plural.
  `Platform_PluginStructuresApiTest` still asserts the field reaches that query —
  both read-side queries share `encodeQueryableDef`.
- `Platform_Admin_Structure`'s fixture takes `Api_Naming.adminField(~name="Plugin")`,
  the same call `PluginBaseFragment.queryNames.singleFieldName` makes — the admin
  fragment hand-declares its names rather than deriving them from the read-model
  name, so singularising `Platform_Plugins` there would have been the guess this
  change exists to remove.

**Validated** against the local hybrid platform: `Catalog_Categories` publishes
`singleQueryField: "Catalog_Category"`, the generated SDL serves
`Catalog_Category(id: ID!)` and `Catalog_CategoryFilter`, a detail query built
from the published name resolves, and the naive `Catalog_Categorie` is rejected
as an unknown field.

The optional follow-up below (`@id` on stream projections) was **not** done — it
is independent of this change and still available.

The plugin structure publishes a queryable's **list** field name and withholds
its **singular** one, although `Api_Naming` computes both from the same call.
Every consumer that wants the single-entity query therefore re-derives it by
guessing an inflection rule — and a rule that differs from `Api_Naming`'s
addresses a field the schema does not contain.

---

## The gap

[Plugin_Structure.res:650](../../reventless/core/src/plugin/component/Plugin_Structure.res#L650)
calls `Api_Naming.queryFieldNamesForReadModel`, which returns four names, and
keeps one:

```rescript
let qf = Api_Naming.queryFieldNamesForReadModel(~plugin=name, ~name=R.Spec.name)
…
queryField: qf.listFieldName,
```

`qf.singleFieldName`, `qf.returnTypeName` and `qf.pluralTypeName` are dropped.
`stateViewDefs` (L675) does the same.

What a consumer needs those names for:

| Wanted | Emitted as | Derivable from `queryField`? |
|---|---|---|
| The single-entity query — `Plugin_Order(id: ID!)` | `singleFieldName` | Only by re-implementing `Api_Naming.singularize`. |
| The filter / order-by input types — `Plugin_OrderFilter`, `Plugin_OrderOrderBy` | `returnTypeName`, which equals `singleFieldName` | Same. |

[Api_Naming.res:14-32](../../reventless/core/src/components/Api/Api_Naming.res#L14-L32)
handles consonant + `y` → `ies`, the `s`/`x`/`z`/`ch`/`sh` → `es` family, and
their inverses. A consumer that assumes the naive "strip a trailing `s`"
turns `Plugin_Categories` into `Plugin_Categorie` — a name nothing serves, for
both the detail query and the filter variables. The failure is quiet at build
time and shows up as a GraphQL validation error against one specific view.

Publishing the name this side already computed removes the guess rather than
asking every consumer to reproduce it correctly.

---

## Goal

`queryableDef` carries the singular query field name, sourced from
`Api_Naming`, for read models and state-view slices alike. Consumers that
derive it locally can stop.

Out of scope: publishing `pluralTypeName` (a consumer holding `queryField`
already has it), and changing any generated name.

---

## Decisions (locked)

| Decision | Choice | Why |
|---|---|---|
| Field name | `singleQueryField` | Sits beside `queryField` and names the same thing in the singular. |
| Type | `@s.matches(stringOptionSchema) option<string>` | Matches `statusField` / `labelFieldSource` / `visibility`: defs persisted before the field existed decode as `None` instead of failing. |
| One field or two | One | `Api_Naming` emits `returnTypeName == singleFieldName` for every queryable; a second field would publish the same string twice and invite them to drift. Say so in the doc comment. |
| Source | `Api_Naming` return value, never a re-derivation | The point of the change. |
| Hand-rolled defs | May omit it | `None` means "not stated", and a consumer falls back to whatever it does today. |

---

## File map

| File | Change |
|---|---|
| [reventless/spec/src/components/Plugin.res](../../reventless/spec/src/components/Plugin.res#L200) | Add `singleQueryField` to `queryableDef` with a doc comment covering both uses (detail query field, filter/order-by type prefix) and the `None` semantics. |
| [reventless/core/src/plugin/component/Plugin_Structure.res](../../reventless/core/src/plugin/component/Plugin_Structure.res#L650) | Set it from `qf.singleFieldName` in `readModelDefs` and `stateViewDefs`. |
| [reventless/core/src/admin/Platform_ComponentDefinitionsApi.res](../../reventless/core/src/admin/Platform_ComponentDefinitionsApi.res#L28) | Add `singleQueryField: String` to the `Platform_ReadSideDef` SDL and to `encodeQueryableDef`. |
| [reventless/core/src/admin/Platform_Admin_Structure.res](../../reventless/core/src/admin/Platform_Admin_Structure.res#L108) | Set it on the `pluginReadModel` fixture. |
| [reventless/core/tests/admin/Platform_ComponentDefinitionsApiTest.res](../../reventless/core/tests/admin/Platform_ComponentDefinitionsApiTest.res) | Assert the field survives the API round trip. |
| [reventless/core/tests/admin/Platform_PluginStructuresApiTest.res](../../reventless/core/tests/admin/Platform_PluginStructuresApiTest.res) | Assert the published value equals `Api_Naming`'s, including for an `-ies` name. |

---

## Steps

1. Add the field to `queryableDef` as `option<string>`, documented in the style
   of its optional neighbours: what it is, what both of its uses are, and that
   `None` means the def predates the field or declines to state it.
2. Populate it in `readModelDefs` and `stateViewDefs` from the `qf` record
   already in scope. Do not call `singularize` at either site — take the name
   `Api_Naming` returned.
3. Extend the component-definitions SDL and encoder; a nullable `String` keeps
   older stored structures decodable.
4. Update the admin structure fixture and both API tests. Add a queryable whose
   name pluralises irregularly (e.g. one ending in `y`) so the test would fail
   against a naive derivation.
5. Run `npm run test` in `reventless-core` and `reventless-local`.

**Validation.** For a plugin with a `-ies` queryable, the published
`singleQueryField` matches the field name in the generated SDL exactly, and a
detail query built from it resolves against the local platform.

**Compatibility.** Additive and nullable: structures persisted before this
lands decode as `None`. Consumers keep their current derivation as the fallback
for `None`, so no consumer is required to update in lockstep.

**Commit.** `feat(plugin): publish singleQueryField on queryableDef`

---

## Optional follow-up — state the projection key with `@id`

Independent of the above, and worth doing on its own merits.

A `StateViewSliceStream` projection establishes its key positionally
(`Set(productId, …)`), so nothing in the state schema says which field is the
key. `Reventless.StateAnnotations.getSpec` then returns no spec, and
[GraphQL_FragmentGenerator.deriveServerCapability](../../reventless/core/src/components/Api/GraphQL_FragmentGenerator.res#L191)
emits `emptyCapability` — the generated queryable gets no filter input and no
order-by at all, so every narrowing a client asks for happens client-side over
one page.

Annotating the key field (`@id productId`) adds an eq filter and a sort field
for it, and marks it `x-reventless-id` in the published JSON schema, which is
how a schema reader tells the row's own key from a reference to another entity.
It changes no storage keying — `spec.ids` is read only by
[SuryToJsonSchema](../../reventless/core/src/components/Api/SuryToJsonSchema.res#L36)
and the SDL generator.

Candidates are the example plugins' stream-projected views under
`examples/online-shop-hybrid` (catalog `Products`, `Categories`, `ProductDemand`;
ordering `AvailableProducts`). The SDL change is additive but does alter the
generated schema, so it needs a redeploy to take effect on a deployed platform.
