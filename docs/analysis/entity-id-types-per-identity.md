# Entity Id types: one type per identity

**Created:** 2026-03-16 · **Revised:** 2026-09-21<br/>
**History:** The first version compared typed Id modules with plain strings and kept the typed
Id, on the grounds that each aggregate's `Id.t` is a distinct type. The revision found that
premise false for every generated spec (F1) and works out what makes it true.<br/>
**Status:** Analysis, no code changed. Verified against `alpha` by reading the PPX,
`Reventless.Id`, `DcbTag`, `Reference`, `Plugin_Structure` and the three online-shop
examples, and by compiling the sealing forms below in a scratch project.

---

## Summary

- **Keep typed Ids, but make them what they claim to be.** Plain strings would save about
  fifteen conversion calls and one type parameter, and would give up the only compile-time
  guard against mixing up entities. Today that guard does not exist either: every
  generated `X.Id.t` is the same type (F1).
- **Ids are recognised by name, not by type.** Every id in a command, event or state is a
  `string`. Tagging, partition inference and read-model keys all find ids by the field
  name `*Id` / `*Ids` (F2).
- **The Id module is per component, and an identity is not.** Many slices, views and plugins
  carry the same order id, and a DCB slice's own Id module is never read (F3).
- **Proposal: one type per identity**, declared once with
  `Reventless.Id.Make({let key = "productId"})`. The key is the DCB tag key, which the
  runtime already treats as the plugin-wide name of "which thing". Every component that
  carries the identity uses that type.
- **For DCB slices, the identity is not the chapter.** The chapter is the default place to
  declare it and a check against it, but it does not define it.
- **The type does not replace `@ref`.** The type says *what* a value is, and `@ref` says
  *which list* to pick it from. When exactly one view is keyed by the identity, the
  reference is derived. When several are, `@ref` chooses and is checked.
- **Nothing changes on the wire.** At runtime the type is a string schema, so no data
  needs migrating.
- **The PPX must go first.** Every id-recognising site accepts only a literal `string`
  (F4). Until that changes, a typed id field silently loses its DCB tag.

---

## Findings

### F1: Every generated Id is the same type

`gen_module_id`
([`ReventlessPpx.ml:119`](../../packages/reventless-ppx/src/ppx/ReventlessPpx.ml#L119))
emits `module Id = Reventless.Id.String`. It runs for every `@@reventless.spec` file
([:796](../../packages/reventless-ppx/src/ppx/ReventlessPpx.ml#L796)), delegate
([:252](../../packages/reventless-ppx/src/ppx/ReventlessPpx.ml#L252)) and DCB source module
([:487](../../packages/reventless-ppx/src/ppx/ReventlessPpx.ml#L487)), unless the spec
declares its own `module Id`. `Id.String` is sealed exactly once
([`Id.res:75`](../../reventless/spec/src/types/Id.res#L75)). An alias does not re-seal, so
all specs share one abstract type. Compiled in a scratch project:

```rescript
module OrderAlias = Id.String
module ProductAlias = Id.String
let aliasMixes = (o: OrderAlias.t): ProductAlias.t => o   // compiles

module ProductId = Id.Make({let key = "productId"})
module CustomerId = Id.Make({let key = "customerId"})
let mix = (p: ProductId.t): CustomerId.t => p              // error: ProductId.t vs CustomerId.t
```

`T` also makes `input` abstract, so `Id.String.make` cannot be called at all; only
`makeFromString` works. The doc comment on `Id.T` ("prevents accidentally mixing identifiers
from different aggregates") describes a guarantee that generated specs do not get.

### F2: Identity lives in field names

Outside the aggregate envelope, the only explicit Id use in the examples is the aggregates
example's `Order_EmailNotification` side effect and its test. Everywhere else, "this is an
order id" comes from the name:

| Where | Rule |
|---|---|
| DCB auto-tagging | `*Id: string` gets a tag keyed by the field name; `*Ids` is singularised ([`DcbTagInference.ml:151-181`](../../packages/reventless-ppx/src/ppx/DcbTagInference.ml#L151)) |
| DCB partition inference | `idFieldsOfProperties` selects `*Id` / `*Ids` by name ([`DcbTag.res:1085`](../../reventless/spec/src/components/DcbTag.res#L1085)) |
| Read-model key | `@id`, else `<singular(name)>Id`, else the sole `*Id` ([`GraphQL_FragmentGenerator.res:331-358`](../../reventless/core/src/components/Api/GraphQL_FragmentGenerator.res#L331)) |
| Reference fallback | with no `@ref`, a consumer "resolves the field to whatever entity the name suggests" ([`Reference.res`](../../reventless/spec/src/components/Reference.res)) |

Nothing recognises `buyer: string` as an id, and an `orderId` that holds a customer id is
accepted everywhere.

### F3: The Id module is per component; an identity is not

| Component | Its `module Id` | What it identifies |
|---|---|---|
| Aggregate | envelope, EventLog, CommandTopic, QueryDb | the stream: one identity |
| ReadModel | required by the Spec ([`ReadModel.res:174`](../../reventless/spec/src/components/ReadModel.res#L174)), used as the storage key | the row: the same identity as the entity it lists |
| StateChangeSlice | required by the Spec, "always `Id.String`" ([`StateChangeSlice.res:53`](../../reventless/spec/src/components/StateChangeSlice.res#L53)); never read; the builders hardcode `Reventless.Id.String` | nothing. The command envelope id is the partition tag value ([`DcbTag.partitionValueOfTags`, :1523](../../reventless/spec/src/components/DcbTag.res#L1523)) |
| StateViewSlice | injected, not in the Spec | nothing. Rows are keyed by `Set(productId, …)` as `string` ([`StateViewSlice.res:117`](../../reventless/spec/src/components/StateViewSlice.res#L117)) |

This rules out the obvious fix. Sealing afresh in every file would make
`PlaceOrder.Id.t ≠ CancelOrder.Id.t ≠ Orders.Id.t` for the same order.

### F4: Everything that recognises an id requires a literal `string`

| Site | Effect on a field typed `ProductId.t` |
|---|---|
| `DcbTagInference.is_string_type` ([:143](../../packages/reventless-ppx/src/ppx/DcbTagInference.ml#L143)): auto-tag, `@partitionTag`, `@crossPartition`, `@dcbTag`, composite | **no DCB tag, no error** |
| `ReferenceInference` ([:100-150](../../packages/reventless-ppx/src/ppx/ReferenceInference.ml#L100)) | `@ref` is an error |
| `OwnerInference.is_string_type` ([:85](../../packages/reventless-ppx/src/ppx/OwnerInference.ml#L85)) | error |
| `StateAnnotations` ([:180](../../packages/reventless-ppx/src/ppx/StateAnnotations.ml#L180)) | `@id` / `@compositeId` / `@subId` are errors |
| `SidecarEmit` ([:80-110](../../packages/reventless-ppx/src/ppx/SidecarEmit.ml#L80)) | `dcbRole` is not `autoString`; kind is `custom` |
| `DcbTag.string`, `Reference.to_` | typed `S.t<string>`, so `@s.matches` does not typecheck |

The first row is the dangerous one. Retyping a field without changing the tagger takes it
out of the consistency boundary, and nothing reports it.

### F5: Id conversion follows no stated rule

- **Two paths for the same value.** `Spec.Id.schema` embeds ids in JSON documents (event
  records, query-DB state), and `Spec.Id.toString` produces infrastructure keys (partition
  keys, grouping, logs). Both appear in the same functions (`EventLog_Operations`,
  `QueryDb_Operations`), and the rule is written down nowhere.
- **Commands and events differ.** `Message.encodeEvent'` takes an id schema, while
  `Message.commandJsonOfCommand'` takes `~idToString`, because `commandJson` already has
  `id: string`.
- **The extension boundary is untyped.** `Extension_Operations` decodes with a hardcoded
  `Reventless.Id.StringPure.schema` and types events as `Message.event'<string, _>`, because
  the source plugin's Id type is not available there. Cross-plugin identities (below) change
  that.

---

## Design: one type per identity

### What an identity is

An identity is a **DCB tag key**: `orderId`, `productId`, `customerId`. The runtime already
reasons in these terms: tags are keyed by the key, partitions are chosen from it, and `*Ids`
arrays are singularised onto it so they meet their producers. It also crosses plugins
unchanged, from catalog's `ProductBecameAvailable({productId})` to ordering's
`SyncCatalogProduct`.

### Declaring one

A sketch of the addition to `Reventless.Id`:

```rescript
module type Identity = {
  include T with type input = string
  let key: string
}

module Make = (K: {let key: string}): Identity => {
  include StringPure
  let key = K.key
  let schema = schema->S.Metadata.set(~id=identityId, key)
}
```

Each application of `Make` to a structure literal yields a fresh abstract type (F1's compile).
`with type input = string` makes `make` usable again. Components refer to the identity
rather than getting their own:

```rescript
// src/Order/OrderId.res
include Reventless.Id.Make({let key = "orderId"})

// Aggregate/Order.res — the stream is keyed by the identity
module Id = OrderId
// StateView/Orders.res — rows are keyed by it
@schema type state = {orderId: OrderId.t, customerId: CustomerId.t, …}
// StateChange/PlaceOrder.res
@schema type command =
  PlaceOrder({orderId: OrderId.t, customerId: CustomerId.t, productIds: array<ProductId.t>})
```

`module Id = OrderId` makes the aggregate's envelope id and every `orderId` field the same
type. The PPX already skips its injection when a spec declares `module Id`, so no injection
change is needed for aggregates and read models. The unread `module Id` on
`StateChangeSlice.Spec` should be removed, because the typed partition field carries the
identity.

### Recognition: syntactic in the PPX, authoritative in metadata

The PPX sees one file and cannot resolve types. It recognises the **shape** `<M>Id.t` (a path
whose last module ends in `Id`), including inside `option<…>` and `array<…>`, and uses it
only to choose the helpers it wraps the field with. The key comes from the schema metadata
that `Make` sets. That gives the runtime one place to ask "is this an identity, and which
one?": `DcbTag`, `Plugin_Structure`, the read-model key, and the sidecar.

- **The tag key follows the type when the field is typed.** `buyer: CustomerId.t` is tagged
  `customerId` without `@dcbTag("customerId")`. Existing fields are unaffected, because every
  tagged id today is named after its key.
- **A name that disagrees with its type is a warning.** `orderId: CustomerId.t` is exactly
  the mix-up this work exists to catch.
- **`DcbTag` and `Reference` need type-preserving helpers** (`S.t<'a> => S.t<'a>`). Their
  metadata is already type-agnostic.
- **Partition inference reads identities.** `idFieldsOfProperties` reads identity metadata
  before names, so the per-slice subtraction works on identities, which is what the
  producer-partition fixpoint ([dcb-partition-key-derivation.md](done/dcb-partition-key-derivation.md)
  F6, rule C) reasons about anyway.

### DCB slices: why not one type per chapter

A DCB slice has no identity of its own. It decides about one, its partition, and mentions
others.

| Option | Verdict |
|---|---|
| Per slice: seal `gen_module_id` afresh | ✗ splits one entity into many types (F3) |
| Per chapter: `src/Order/` *is* `OrderId` | ✗ as the definition |
| **Per identity key, declared in the owning chapter by default** | ✓ |
| Generated catalog: `generate-plugin` scans `*Id` fields and emits the types | migration aid only; it would make the name-based guess authoritative |

The chapter cannot be the identity, for these reasons:

- **Chapters are optional.** A slice directly under `src/StateChange/` has none
  ([`Discovery.chapterOf`](../../reventless/spec/src/generator/Discovery.res#L38)).
- **A chapter can own two identities.** `Notification` carries `recipientId` and `sourceId`.
- **A chapter mentions identities it does not own.** `Order` carries `customerId` and
  `productIds`, so its fields need other chapters' types anyway.
- **A chapter can hold another plugin's identity.** Ordering's `CatalogProduct` chapter
  replicates catalog's products.
- **Folder layout must not decide identity.** The partition-key analysis kept the chapter as
  a check, not an input, for this reason. A type named after a folder turns a rename into a
  type change.

What the chapter is good for:

- **The default home.** `src/Order/OrderId.res` works: discovery ignores a file directly
  inside a chapter folder, and the plugin's flat namespace makes it visible to every chapter.
  The name must not collide with an existing module. Hybrid ordering has a `Customer` module
  but no `CustomerId`.
- **The check.** Report a slice whose partition identity is not declared in its own chapter,
  e.g. `categoryId` partitioning a slice under `Product/`.

### Cross-plugin identities

Plugins already depend at compile time on each other's `*-spec` packages; ordering depends on
`online-shop-dcb-catalog-spec`. That published contract is where catalog's `ProductId`
belongs, used as `CatalogSpec.ProductId.t` in the extension-point events, in
`SyncCatalogProduct` and in `AvailableProducts`.

- **The `*-spec` package needs `Make`.** It depends only on `sury` today, so it either
  depends on `reventless-spec` or carries a copy of `Make`.
- **The extension mapping becomes the typed seam** where F5's untyped boundary is today.
- **A local re-declaration of a foreign identity stays possible.** Tag keys still match,
  but the compiler no longer relates the two types. That should be a deliberate choice,
  not the default.

### Wire compatibility

JSON, GraphQL and storage are unchanged. The schema is `S.string`, and tag keys stay the same
for every existing field. Adoption is source-only, plugin by plugin, with no event-log or
read-model migration.

---

## Referencing views

The type says which views are eligible, and it decides the reference whenever that set has one
member.

- **A view is keyed by an identity.** The key ladder (F2) names one field. When that field is
  typed `ProductId.t`, the view's key is known from metadata rather than guessed from the
  name.
- **Every `@ref` in the examples already points at a view keyed by the field's identity.**
  `PlaceOrder.productIds` → `AvailableProducts` (`productId`); `AddProduct.categoryId` →
  `Categories` (`categoryId`).

| Views keyed by the field's identity | Reference |
|---|---|
| exactly one | derived; no `@ref` needed |
| several (DCB catalog: `Products` and `ProductDemand`, both keyed by `productId`) | `@ref` chooses, and must name one of them |
| none | reported: nothing lists this identity |

This belongs in `Plugin_Structure.extractReferences`
([:593](../../reventless/core/src/plugin/component/Plugin_Structure.res#L593)), which already
sees every view schema in the plugin. It emits the same `{fieldName, entity, plugin}` records
as today, so clients of the plugin structure are unaffected.

The type cannot choose **which list**. `AvailableProducts` is a filtered subset of the
products, and preferring it to `Products` is a product decision. `@ref` stays for that
choice, and only needs writing when there is one.

StateViewSlice row keys should be typed too. `Projection.action` becomes generic in its key
instead of `action<string, _>`. Otherwise `Set` is the one place where a view could be keyed
by the wrong identity with no error.

---

## Costs

- **PPX:** the F4 sites accept the identity shape; the tag key follows the type; a
  name/type mismatch warns. One recognition helper, used at about a dozen sites.
- **Spec:** `Id.Identity`, `Id.Make`, identity metadata; type-preserving `DcbTag` /
  `Reference` helpers; the partition inference and read-model key read metadata first; a
  generic key in `Projection.action`.
- **Handlers:** id collections in state, e.g. `array<string>` in DCB
  [`PlaceOrder_Behavior.res:6`](../../examples/online-shop-dcb/ordering/src/Order/StateChange/PlaceOrder_Behavior.res#L6),
  become `array<OrderId.t>`. `==` and `Array.includes` work on abstract types; `Dict` keys
  need `toString`. Each conversion marks an edge, which is intended.
- **Tests:** literals become `makeFromString`; `StringPure` stays for inline fixture specs.
- **Unchanged:** stored data, GraphQL, and the plugin-structure records.

## Options

Each step ships on its own, in this order.

1. **`Id.Identity`, `Id.Make` and identity metadata.** Additive. Correct `Id.T`'s doc
   comment (F1).
2. **The runtime accepts identity schemas:** typed `DcbTag` / `Reference` helpers; the
   partition inference, read-model key and `extractReferences` read metadata before names.
   Additive.
3. **The PPX accepts identity-typed fields** at every F4 site, derives the tag key from the
   type, and warns on a name/type mismatch. Nothing may write a typed id before this lands.
4. **Derived and checked references.** Runtime only.
5. **Migrate one example plugin**, including one cross-plugin identity in its `*-spec`
   package. Measure the handler, projection and test churn before recommending the rest.
6. **Point component Ids at identities.** Aggregates and read models write
   `module Id = <Identity>`; remove `StateChangeSlice.Spec.Id`; type StateViewSlice row keys.
7. **Document the conversion rule (F5)**: schema inside JSON documents, `toString` for
   infrastructure keys.

**Not recommended:** sealing afresh per file (F3); one type per chapter as the definition of
identity; a generated catalog as anything but a one-off migration aid.

## Open questions

- **Composite partitions** (`@compositePartitionTag`): is the composite its own identity
  (`Make` over a record), or a pair of identities?
- **Validation per identity:** should `Make` accept a refinement (UUID, prefix), or does that
  belong to semantic types?
- **Should an untyped `*Id: string` eventually warn?**
- **Existing data where name and key differ:** retyping such a field would change its tag key.
  No example has one. A migration should refuse the retype, or keep the field-name key with
  `@dcbTag`.
- **The `*-spec` package:** depend on `reventless-spec`, or carry a copy of `Make`?
