# Plan: Infer a queryable's key field instead of demanding `@id`

## Status: ✅ Done

Landed as specified. What the SDL looks like now, against the local hybrid
platform: **7 `OrderField` enums + 7 `OrderBy` inputs where there were zero**,
and every queryable's filter carries its key's `…Eq` field —
`Catalog_CategoryFilter.categoryIdEq`, `Ordering_CustomerFilter.customerIdEq`,
and so on. `Platform_ComponentDefinitions` reports `idFieldSource: "annotation"`
for `ProductDemand` and `"convention"` / `"sole"` for the rest; `Plugins` reports
`null` on both, as its state has no `*Id` field to name.

Two notes on what differed:

- **One existing test asserted the old behaviour** and had to be rewritten, not
  patched: `GraphQL_SchemaInspectorTest`'s "read model with no annotations emits
  the unchanged search-only Filter". Its `plainState` fixture has a sole `*Id`
  field, so it now gets that key's filter and order-by. It became two tests — the
  inferred-key case, and a new keyless fixture for the empty capability that
  remains.
- **The `Platform_UiFragments` view picked up a key too** (`pluginId`, rung
  `"sole"`), which was not in the plan's survey. Checked against its projection:
  `Set(pluginId, {pluginId, …})` — the inference is right.

Verified end to end: `Ordering_Customers(filter: {customerIdEq: "cust-9"},
orderBy: {field: customerId, direction: ASC})` narrows and excludes correctly,
the row carries `customerId`, and re-fetching by it resolves.

A read-side component whose state carries no `@id` gets **no per-field filter and
no order-by at all** — not a reduced surface, none. Today that is every queryable
in every example. The fix is not to annotate them: it is to let the capability
deriver answer the question the way `labelField` already answers its own, and
reserve the annotation for the cases inference provably cannot settle.

---

## The gap

[GraphQL_FragmentGenerator.deriveServerCapability](../../../reventless/core/src/components/Api/GraphQL_FragmentGenerator.res#L190)
opens with

```rescript
switch Reventless.StateAnnotations.getSpec(schema) {
| None => emptyCapability
```

and `emptyCapability` means `filterFields: []`, `sortFields: []`. The capability
is the sole input to the generated
[filter input](../../../reventless/core/src/components/Api/GraphQL_FragmentGenerator.res#L264)
and to the
[order-by pair](../../../reventless/core/src/components/Api/GraphQL_FragmentGenerator.res#L286),
which is emitted **only** when `sortFields` is non-empty.

Measured against the hybrid example's live SDL (1760 lines):

```graphql
input Catalog_CategoryFilter {   # and Product, ProductDemand, Order,
  search: String                 # Customer, AvailableProduct — identical
  searchPrefix: String
  ids: [ID!]
}
```

Three base fields on every queryable, and **zero `OrderBy` types in the whole
schema**. `grep -rl "@id \|@index\|@subId" examples/*/*/src` returns nothing.
Every narrowing and every sort an AutoUI client asks for is therefore done
client-side over one page — wrong past the first page, not merely slow.

### Why inference is safe here

`@id` on a read-side spec is inert outside the schema surface:

- The PPX emits `let makeId = state => state.itemId` from it, and `makeId` has
  **no consumer anywhere in the workspace** (core, local, aws, infra, spec, or a
  generated example `Plugin.res`). The only `makeId` hits are the unrelated
  `Plugin.makeId` / `Counter.makeId`.
- Per-field filters execute as generic predicates over fetched items in
  [QueryDbListQuery](../../../reventless/core/src/components/Api/QueryDbListQuery.res#L101)
  (`filterDict->Dict.get(f.name ++ "Eq")`, then compare). No key routing. The
  deployed path funnels into the same shared spec as its fallback in
  [PgQueryResolver_Lambda](../../../reventless/aws/src/adapter/QueryDb/PgQueryResolver_Lambda.res#L245).

So a wrong key guess costs an offered filter on a non-key field, not a wrong
result. `@subId` and `@index` are different in kind — they provision a sort key
and a GSI — and stay declaration-only.

### The house pattern already exists

`labelField` does not demand an annotation: `Plugin_Structure` runs a ladder
(annotation → convention → position → fallback) and publishes **which rung
answered** as `labelFieldSource`, so a consumer can rank a declaration against a
guess. `deriveServerCapability`'s `| None => emptyCapability` is the outlier.

---

## What inference actually resolves

Two rules, measured against the six hybrid queryables:

| Queryable | `*Id` fields in state | sole `*Id` | `singular(name) ++ "Id"` | Resolved by |
|---|---|---|---|---|
| `Categories` | `categoryId` | ✅ | ✅ | inference |
| `Products` | `productId`, `categoryId` | ✗ ambiguous | ✅ `productId` | inference |
| `Orders` | `orderId`, `customerId`, `productIds` | ✗ ambiguous | ✅ `orderId` | inference |
| `AvailableProducts` | `productId` | ✅ | ✗ (`availableProductId`) | inference |
| `ProductDemand` | `productId`, `categoryId` | ✗ ambiguous | ✗ (`productDemandId`) | **needs `@id`** |
| `Customers` | **none** | ✗ | ✗ | **needs a key field** |

Four of six for free. The annotation must stay available, because the last two
are real: `ProductDemand` is genuinely ambiguous, and `Customers` has nothing to
annotate — its state never stores the key it is keyed by.

---

## Does `Customers` need to carry its own key?

Verified live against the local platform, seeded with one customer `cust-42`:

| Query | Result |
|---|---|
| `Ordering_Customer(id: "cust-42")` | ✅ resolves — the byId resolver takes the **raw** local id (`ops.loadStream(id)`, no global-id decoding) |
| `Ordering_Customers(filter: {ids: ["cust-42"]})` | ✅ resolves |
| the row's own `id` field | `"T3JkZXJpbmdfQ3VzdG9tZXI6Y3VzdC00Mg=="` — a Relay global id, `btoa("Ordering_Customer:cust-42")` |
| `Ordering_Customer(id: "T3JkZXJpbmdfQ3VzdG9tZXI6Y3VzdC00Mg==")` | ❌ **null** |
| `node(id: "T3JkZXJpbmdfQ3VzdG9tZXI6Y3VzdC00Mg==")` | ✅ resolves |

So it is **not** needed for navigation in either direction: a client holding
`order.customerId` reaches the customer, and a client holding a row re-fetches it
through Relay's `node`. What the missing field costs is that **a `Customers` row
does not state which entity it is about**: the only key on it is a global id that
identifies the row to `node` but cannot be compared to anything, so the row
cannot be eq-filtered by customer, sorted by customer, or correlated with
`Orders.customerId` without base64-decoding `id` out of band. Every other example
view carries its raw key (`Ordering_Order` exposes both `orderId: ID!` and the
global `id`), so `Customers` is the odd one out.

**Verdict: yes — add it.** Not to unlock the filter surface (inference would not
help without it either), but because a read model that cannot say which entity a
row is about is incomplete. Adding `customerId` also removes the need for any
annotation there: both inference rules then resolve it.

The wider id-form disagreement — four doors with three contracts, and the two
providers advertising different forms on a row — is a separate defect and is
**out of scope** here. Filed as
[queryable-id-contract-parity](queryable-id-contract-parity.md).

---

## Goal

`deriveServerCapability` resolves a key field by a documented ladder, so every
queryable gets an eq filter and a sort field for its key without ceremony; the
rung that answered is published on `queryableDef` beside `labelFieldSource`; and
the two example components inference cannot settle are fixed at the source.

Out of scope: composite keys (`@compositeId` stays declaration-only), `@subId` /
`@index` inference (both provision storage), emitting `x-reventless-id` for an
inferred key, and the global-id round-trip asymmetry.

---

## Decisions (locked)

| Decision | Choice | Why |
|---|---|---|
| Ladder order | `@id` declaration → `singular(name) ++ "Id"` field match → sole `*Id`-suffixed field → decline | Convention can only fire on a field that exists, so it cannot pick a phantom; it beats "sole" because a view with one FK and no own key would otherwise be keyed by the FK. |
| `~entityName` on `deriveServerCapability` | Required, not optional | All four call sites have a name in scope. An optional arg lets a caller silently lose the convention rung — the quiet-wrong-answer failure this work exists to remove. |
| Inferred key's capability | Identical to a declared `@id` — eq filter **and** sort field | The point is that inference produces what the annotation would. Sorting by a partition key is of marginal value on the AWS resolver; that is true of a declared `@id` too and is not a reason to split the behaviour. |
| Provenance | New `idField` + `idFieldSource` on `queryableDef` (`"annotation"` / `"convention"` / `"sole"`; both `None` when unresolved) | Mirrors `labelField` / `labelFieldSource` exactly, and travels with `singleQueryField` to the same consumers. |
| `x-reventless-id` | Stays declaration-only | The JSON Schema has no room for provenance; a guess printed as a flat boolean is indistinguishable from a declaration. Revisit with `x-reventless-id-source` if a consumer needs it. |
| Example annotations | Exactly one: `@id productId` on `ProductDemand` | Every other view is resolved by the ladder once `Customers` carries its key. |

---

## Part 1 — Framework

| File | Change |
|---|---|
| [GraphQL_FragmentGenerator.res](../../../reventless/core/src/components/Api/GraphQL_FragmentGenerator.res#L190) | Add `resolveKeyField(~entityName, schema): option<(string, string)>` (field, rung). Replace `| None => emptyCapability` with: run the ladder; on a hit, push the eq filter + sort field and continue as the `Some(spec)` branch does. In the `Some(spec)` branch, keep `spec.ids` first — a declaration always wins. |
| same | `deriveServerCapability` gains `~entityName: string`; update the four call sites ([:567](../../../reventless/core/src/components/Api/GraphQL_FragmentGenerator.res#L567), [QueryDbResolvers_GraphQL:282](../../../reventless/local/src/adapter/QueryDb/QueryDbResolvers_GraphQL.res#L282), [PgQueryResolverEntryPoint_Ops:146](../../../reventless/aws/src/adapter/Runtime/PgQueryResolverEntryPoint_Ops.res#L146), [QueryDbResolvers_AppSync:208](../../../reventless/aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res#L208)), each of which already has the read-model name in scope. |
| [Plugin.res](../../../reventless/spec/src/components/Plugin.res) | Add `idField` and `idFieldSource` to `queryableDef`, both `@s.matches(stringOptionSchema) option<string>`, documented in the style of `labelFieldSource` — the rungs, and that `None` means unresolved or a def that predates the fields. |
| [Plugin_Structure.res](../../../reventless/core/src/plugin/component/Plugin_Structure.res) | Populate both in `readModelDefs` and `stateViewDefs` from the same resolver the capability uses — one call, never a second derivation. |
| [Platform_ComponentDefinitionsApi.res](../../../reventless/core/src/admin/Platform_ComponentDefinitionsApi.res#L30) | Add `idField: String` and `idFieldSource: String` to `Platform_ReadSideDef` and to `encodeQueryableDef` (nullable, same reason as `singleQueryField`). |
| [Platform_Admin_Structure.res](../../../reventless/core/src/admin/Platform_Admin_Structure.res) | Set them on the `pluginReadModel` fixture (the Plugins read model is keyed by plugin id). |

**Tests**

| File | Assertion |
|---|---|
| [GraphQL_FragmentGeneratorTest](../../../reventless/core/tests/api/GraphQL_FragmentGeneratorTest.res) | One case per rung, plus the two declines: several `*Id` fields with no name match, and no `*Id` field at all. Assert a declared `@id` outranks a conflicting convention match. |
| [PluginStructureTest](../../../reventless/core/tests/plugin/PluginStructureTest.res) | `idField` / `idFieldSource` on built defs; `PsAnnotatedView` (declared `@id itemId`) reports `"annotation"`, `PsCategoriesView` reports a guess. |
| [Platform_ComponentDefinitionsApiTest](../../../reventless/core/tests/admin/Platform_ComponentDefinitionsApiTest.res) | Both fields survive the API round trip; unstated encodes as `null`; SDL types them nullable. |

---

## Part 2 — The one necessary annotation

| File | Change |
|---|---|
| [ProductDemand.res](../../../examples/online-shop-hybrid/catalog/src/Product/StateViewSliceStream/ProductDemand.res) | `@id productId` on the state field. Two `*Id` fields and a name (`ProductDemand`) that yields no matching field, so the ladder correctly declines — this is the case the annotation exists for. |

No other example needs one. Adding annotations the ladder already resolves would
re-introduce exactly the ceremony this plan removes.

---

## Part 3 — `Customers` carries its key

| File | Change |
|---|---|
| [Customers.res](../../../examples/online-shop-hybrid/ordering/src/Customer/ReadModelStream/Customers.res) | Add `customerId: string` to `@schema type state`, first field. No annotation — the ladder resolves it by both rules. Comment why a read model states its own key: the row's `id` is a Relay global id the byId query does not accept, so without this the row cannot be re-fetched or correlated with `Orders.customerId`. |
| [Customers_Projections.res](../../../examples/online-shop-hybrid/ordering/src/Customer/ReadModelStream/Customers_Projections.res) | Set it in both `UpdateWithDefault` defaults: `customerId: id` in `CustomerMapping`, `customerId` in `CustomerOrdersMapping`. Both sources already agree on the key — the aggregate's instance id and the DCB event's `customerId` — which is why one field can serve both. |
| the plugin's GWT tests | Update expected state records for the new field. |

State shape change ⇒ existing rows lack the field. Per the repo convention this
is an alpha wipe, not a migration.

---

## Steps

1. Add `resolveKeyField` + the ladder, thread `~entityName`, update the four call
   sites. Unit-test the rungs first — they are the whole risk surface.
2. Add `idField` / `idFieldSource` to `queryableDef`, populate from the same
   resolver, extend the SDL + encoder + admin fixture.
3. Annotate `ProductDemand`.
4. Add `customerId` to `Customers` and both mappings; fix the GWT expectations.
5. Root `pnpm run build` (zero warnings), full `pnpm test`, `test:projects`,
   `check:outputs`.
6. Diff the generated SDL before/after against a running local hybrid platform.

**Validation.** Against the local hybrid platform: every queryable's filter input
gains its key's `…Eq` field, an `OrderBy` enum + input appears for each (there
are none today), `Ordering_Customer` exposes `customerId` and a row fetched from
a list can be re-fetched using it, and `Platform_ComponentDefinitions` reports
`idFieldSource: "annotation"` for `ProductDemand` and a guess rung for the rest.

**Compatibility.** The `queryableDef` fields are additive and nullable, so
structures persisted earlier decode as `None`. The SDL grows filter/order-by
surface — additive for clients, but a deployed platform needs a redeploy to
serve it. `deriveServerCapability`'s signature change is internal; the four call
sites are in this repo.

**Commit.** `feat(api): infer a queryable's key field and publish its provenance`

---

## Backlog spin-off — the id contract

Filed as [queryable-id-contract-parity](queryable-id-contract-parity.md):
the four id-accepting doors take different id forms, and the local adapter
advertises a Relay global id on a row where the AWS adapter advertises the raw
one — so the same client query returns a row on one provider and nothing on the
other. A resolver-contract question, not a schema-derivation one.
