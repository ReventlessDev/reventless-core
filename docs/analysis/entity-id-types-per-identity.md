# Entity Id types: one type per identity

**Created:** 2026-03-16 · **Revised:** 2026-09-21<br/>
**History:** The first version compared typed Id modules with plain strings and kept the typed
Id, on the grounds that each aggregate's `Id.t` is a distinct type. The revision found that
premise false for every generated spec (F1) and works out what makes it true.<br/>
**Status:** Analysis, no code changed. Verified against `alpha` by reading the PPX,
`Reventless.Id`, `DcbTag`, `Reference`, `Plugin_Structure` and the three online-shop
examples, and by compiling the sealing forms below in a scratch project.<br/>
**Planned out in:** [entity-id-types-per-identity.md](../plans/done/entity-id-types-per-identity.md).

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
  `Reventless.Id.Make({let key = "productId"})`. In DCB the key is the tag key, which the
  runtime already treats as the plugin-wide name of "which thing". Every component that
  carries the identity uses that type.
- **For DCB slices, the identity is not the chapter.** The chapter is the default place to
  declare it and a check against it, but it does not define it.
- **The type does not replace `@ref`.** The type says *what* a value is, and `@ref` says
  *which list* to pick it from. When exactly one view is keyed by the identity, the
  reference is derived. When several are, `@ref` chooses and is checked.
- **Aggregates and read models use the same identities.** An aggregate's own id travels in
  the envelope, so it adopts an identity with `module Id = OrderId` and no runtime change.
  Read models need two fixes: their projections are string-typed, and the read-model key
  rule cannot see the row's identity, which today mislabels the aggregates example's
  `Orders` (F6).
- **Nothing changes on the wire.** At runtime the type is a string schema, so no data
  needs migrating.
- **The PPX must go first for DCB.** Every id-recognising site accepts only a literal
  `string` (F4). Until that changes, a typed id field in a DCB slice silently loses its tag.
  Aggregates carry no DCB tags, so they are the safe place to start.

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

### F6: A read model's row identity is invisible, in its projections and in its key

- **Projections drop to `string`.** `Projection.Mapping` carries `module SourceId: Id.T`, yet
  `project` takes `Message.event'<string, _>` and returns `action<string, _>`
  ([`Projection.res:98`](../../reventless/spec/src/types/Projection.res#L98)). The row key
  in `Set(id, …)` is therefore a plain string whatever the read model's `module Id` says.
- **The row identity is not in the state.** An aggregate's read model is keyed by the
  envelope id. None of the aggregates example's read models (`Categories`, `Products`,
  `AvailableProducts`, `Customers`, `Orders`) has its own id in its state.
- **The key rule then answers from the wrong field.** `classifyKeyField`
  ([`GraphQL_FragmentGenerator.res:331`](../../reventless/core/src/components/Api/GraphQL_FragmentGenerator.res#L331))
  only looks at state fields. For `Orders = {customerId, productIds, lifecycle}` it finds no
  `orderId`, takes the sole `*Id` field, and resolves the key to **`customerId`**.
  `Plugin_Structure` publishes that as the view's key and builds the generated filter and
  order-by on it. This happens today, independent of identity types: the rule's own
  comment says convention outranks sole "so a view carrying one foreign key and no key of
  its own is not keyed by the foreign key", and for an aggregate read model the
  convention rung can never match.

---

## Design: one type per identity

### What an identity is

An identity is named by its **key**: `orderId`, `productId`, `customerId`. In DCB the key is
the tag key, and the runtime already reasons in these terms: tags are keyed by it,
partitions are chosen from it, and `*Ids` arrays are singularised onto it so they meet their
producers. It also crosses plugins unchanged, from catalog's
`ProductBecameAvailable({productId})` to ordering's `SyncCatalogProduct`. Aggregates have no
tags, and for them the key is the name that references and read-model keys use.

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
  let schema = schema->Semantic.mark(~id=Semantic.Id.identity, ~payload=IdentityOf({key: K.key}))
}
```

The identity is a **semantic**, not new metadata. `Semantic` is the closed vocabulary for
"what a field's value is", and its schema walk already reads every semantic generically.

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
  `customerId` without `@dcbTag("customerId")`. An explicit `@dcbTag("k")` still wins. Existing
  fields are unaffected, because every tagged id today is named after its key.
- **A name that is another identity's key is a warning.** `orderId: CustomerId.t` is exactly
  the mix-up this work exists to catch. A role name is not: `sellerId: CustomerId.t` is
  fine as long as no `SellerId` exists. Only a check that sees the plugin's identities can
  tell the two apart, so this belongs beside `check:dcb-scope`, not in the per-file PPX.
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

### Aggregates and read models

The same identities apply. What differs is where the aggregate's own id sits, and that
read models need their projections and key rule to see it.

- **The aggregate's id is in the envelope, not the payload.** `Order.Place` has no `orderId`
  field. `module Id = OrderId` types the envelope, and the runtime already threads
  `Spec.Id.t` generically through EventLog, CommandTopic, QueryDb and callbacks, so nothing
  there changes. Payload fields that name other entities are typed as in a slice:
  `Place({customerId: CustomerId.t, productIds: array<ProductId.t>})`.
- **There is no tag to lose.** Automatic DCB tagging runs only in slice folders, which is why
  the aggregates example writes `@noDcbTag` on `Order.Place`. F4's silent row does not apply;
  the remaining string-only sites (`@ref`, `@owner`, `@id`) fail with a compile error. A gap
  in an aggregate is therefore loud, which makes aggregates the safe first adopter.
- **Event mappings gain the most.** `EventMapping.map` is already typed
  `(Source.Id.t, …) => array<action<Target.Id.t, …>>`
  ([`EventMapping.res:89`](../../reventless/spec/src/types/EventMapping.res#L89)), but both are
  the same type today (F1). A mapping from `Order` to another aggregate that reuses the order
  id as the target's id compiles now and becomes an error with identities. The example's
  `AutoShipMapping` maps `Order` to `Order` and stays unchanged.
- **Declare the identity in its own file, not in the aggregate.** `module Id = Make(…)`
  inside `Order.res`, referred to as `Order.Id.t`, breaks as soon as two aggregates mention
  each other, because ReScript forbids cyclic module dependencies. `OrderId.res` beside the
  aggregate avoids that, and it serves a hybrid plugin in which aggregates and DCB slices
  share the identity. An aggregate folder is already one entity, so the chapter question
  does not arise.
- **A read model's row identity is its `module Id`.** For a read model, write
  `module Id = OrderId`; this states the row identity F6 found missing.
  - The key rule consults it before the state fields.
  - `customerId: CustomerId.t` in the state is then visibly a foreign identity and can
    never be the key.
  - The projection is typed by it: `project` takes `event'<SourceId.t, _>` and returns
    `action<Id.t, _>`, the same generic key the StateViewSlice needs.

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

JSON, GraphQL and storage are unchanged for every existing field. The schema is `S.string`,
and tag keys stay the same. Adoption is source-only, plugin by plugin, with no event-log or
read-model migration.

**GraphQL typing.** `SchemaType.shapeOf`
([:131](../../reventless/core/src/components/Api/SchemaType.res#L131)) types a string field as
`ID` when it is tagged or referenced, and otherwise by its `*Id` name. It must also type an
identity as `ID`. Otherwise `buyer: CustomerId.t` in an aggregate, which is untagged and
unreferenced, would be published as `String` and lose its id-ness. Newly typed fields whose
name does not end in `Id` then change from `String` to `ID`. Clients do not need to know
this in advance: every mutation argument already carries the type the SDL declares, as
`x-reventless-graphql-type` (`Plugin_Structure.annotateArgTypes`), rendered by the same call
that writes the SDL. A client that honours that key cannot disagree with the server.

**Name-based consumers degrade; they do not break.** A client that recognises entity links,
reference cells or drill targets by the `*Id` name shows `buyer: CustomerId.t` as plain text
until it reads the identity semantic. The semantic's key (`customerId`) gives the same entity
stem the name did, so moving to it is a local change for such a client.

---

## Referencing views

The type says which views are eligible, and it decides the reference whenever that set has one
member.

- **A view is keyed by an identity.** For a read model it is the `module Id`. For a
  StateViewSlice the key rule (F2) names one field, and when that field is typed
  `ProductId.t` the key is known from metadata rather than guessed from the name.
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
as today, so clients that resolve references from those records need no change. (Clients
that recognise ids by name are covered under Wire compatibility.)

The type cannot choose **which list**. `AvailableProducts` is a filtered subset of the
products, and preferring it to `Products` is a product decision. `@ref` stays for that
choice, and only needs writing when there is one.

Row keys should be typed too, for read models and StateViewSlices alike. `Projection.action`
becomes generic in its key instead of `action<string, _>`. Otherwise `Set` is the one place
where a view could be keyed by the wrong identity with no error.

---

## Costs

- **PPX:** the F4 sites accept the identity shape; the tag key follows the type unless
  `@dcbTag` overrides it; spec packages skip `module Id` injection. One recognition helper,
  used at about a dozen sites.
- **Spec:** `Id.Identity`, `Id.Make`, the `identity` semantic and an identity on
  `ReferenceTo`; type-preserving `DcbTag` / `Reference` helpers; the partition inference reads
  the semantic first; the read-model key reads a read model's `module Id` first; projections
  typed by `SourceId` with a generic key in `Projection.action`.
- **Event mappings:** a mapping between different aggregates converts the id explicitly.
- **Checks:** beside `check:dcb-scope`, a field named after another identity's key, and an
  untyped field whose key has a declared identity.
- **Handlers:** id collections in state, e.g. `array<string>` in DCB
  [`PlaceOrder_Behavior.res:6`](../../examples/online-shop-dcb/ordering/src/Order/StateChange/PlaceOrder_Behavior.res#L6),
  become `array<OrderId.t>`. `==` and `Array.includes` work on abstract types; `Dict` keys
  need `toString`. Each conversion marks an edge, which is intended.
- **Tests:** literals become `makeFromString`; `StringPure` stays for inline fixture specs.
- **GraphQL:** `SchemaType` types an identity as `ID`.
- **Unchanged:** stored data, the SDL of every field not retyped, and the plugin-structure
  records.

## Options

Step 0 is independent. Steps 1–7 ship one at a time, in this order.

0. **Stop keying aggregate read models by a foreign id (F6).** Until read models declare
   their identity, the key rule should not apply its "sole `*Id`" rung to a read model,
   whose row is keyed by the envelope id rather than a state field. `Orders` then reports
   no key instead of `customerId`. Keep the filter and order-by that the sole field
   produced: removing a generated filter is an SDL break for any client using it, and
   nothing outside core reads the published key. That replaces the stated invariant ("the
   published key and the filter key cannot disagree") with a weaker one: the key is always
   filterable, but not every filterable field is the key. This is a fix to today's
   behaviour and needs no identities.
1. **`Id.Identity`, `Id.Make`, and the `identity` semantic** with `ReferenceTo` carrying an
   optional identity (open question 2), emitted to JSON Schema, and `SchemaType` typing an
   identity as `ID`. Additive. Correct `Id.T`'s doc comment (F1).
2. **The runtime accepts identity schemas:** typed `DcbTag` / `Reference` helpers; the
   partition inference and `extractReferences` read metadata before names; the read-model
   key reads a read model's `module Id` first. Additive.
3. **The PPX accepts identity-typed fields** at every F4 site and derives the tag key from the
   type unless `@dcbTag("k")` says otherwise. No DCB slice may carry a typed id before this
   lands; an aggregate may, because its gaps are compile errors.
4. **Derived and checked references**, plus the identity-name check and the untyped-field
   report (open question 3). Runtime and `check:dcb-scope` only.
5. **Migrate the aggregates example first**, including the cross-plugin `ProductId` in its
   `*-spec` package, whose `module Id` injection is skipped first (open question 5). It
   exercises the envelope, event mappings, read-model keys and projections without the tag
   risk. Then migrate one DCB plugin. Measure the handler, projection and test churn
   before recommending the rest.
6. **Point component Ids at identities.** Aggregates and read models write
   `module Id = <Identity>`; remove `StateChangeSlice.Spec.Id`; type projections by `SourceId`
   and row keys for read models and StateViewSlices.
7. **Document the conversion rule (F5)**: schema inside JSON documents, `toString` for
   infrastructure keys.

**Not recommended:** sealing afresh per file (F3); one type per chapter as the definition of
identity; a generated catalog as anything but a one-off migration aid.

## Open questions and recommendations

### 1. Composite partitions: one identity, or several?

**Recommendation: neither for now. Composite members stay `string`, and nothing is built
until something references a composite as a whole.**

The one composite shape in the tree (a resource sync keyed by `{environment, resourceName}`,
fixture `EpCompositeSlice.res`) has members that are not identities. `environment` is a
low-cardinality prefix that exists to spread fences, and no field anywhere names "a resource"
by the joined value. Typing the members would claim entity-hood they do not have. A
`Make`-over-record identity would be a new representation (the join lives in
`DcbTag.compositePartitionMember`, not in the value) without a consumer to justify it.
The composite pass keeps its `string` check, so none of this blocks the rest.

**Revisit when** a field needs to hold a composite key as a value: a reference to a
composite-keyed view, or a command that addresses such an entity by one id.

### 2. Validation per identity: in `Make`, or in semantic types?

**Recommendation: `Make` takes no refinement. The identity *is* a semantic, and a reference to
an identity carries it.**

- **An identity says which entity, not what shape.** UUID or prefix formats describe the
  representation, which the semantic vocabulary and `Id.T`'s own extensibility already cover:
  a hand-written `Identity` with its own `schema` stays possible. No example needs one, so
  `Make` should not grow a parameter for it.
- **Add `identity` to the closed `Semantic` vocabulary** (`IdentityOf({key})`) rather than a
  new metadata id. The schema walk then reads identities with no new branch.
- **Mind the one-marker rule.** A schema carries exactly one semantic, and `Reference.to_`
  writes `ReferenceTo`. An `@ref` on an identity-typed field would therefore erase the
  identity. Extend `referenceTarget` with `identity: option<string>` so a reference states
  both facts. `Semantic.mark` is already type-preserving (`S.t<'a> => S.t<'a>`), which is
  most of the typed-helper work in step 2.

### 3. Should an untyped `*Id: string` warn?

**Recommendation: yes, but only when an identity for that key is declared in scope, and as a
report from `check:dcb-scope`, not a PPX warning.**

A blanket warning on every `*Id: string` would fire on every existing plugin and on plugins
that never adopt identities, and the per-file PPX cannot know which identities exist. The
precise mistake is narrower: `ProductId` is declared, and a field still says
`productId: string`. That is the half-migrated state where the compiler guards some uses and
not others. Report it where the whole plugin is visible (step 4), so adopting identities is
opt-in per plugin and, once adopted, complete by check.

### 4. Existing data where a field's name and its identity key differ

**Recommendation: preserve the stored key with an explicit `@dcbTag("<old key>")` rather than
refusing the retype.**

With the rule that an explicit `@dcbTag` wins (§ Recognition), retyping
`sellerId: string` to `sellerId: CustomerId.t @dcbTag("sellerId")` keeps every stored tag
matching, gains the type, and changes no data. A migration that retypes a field whose name
is not its identity's key writes the annotation. Moving the data onto the identity's key
is then a separate, deliberate event-log migration, not a side effect of a type change. No
example has such a field today, so this is a rule for the migration, not a task.

### 5. `*-spec` packages: depend on `reventless-spec`, or copy `Make`?

**Recommendation: depend on `reventless-spec`, and first make the PPX skip `module Id`
injection in spec packages.**

- **A copy would drift.** `Make` marks the schema with a semantic from a closed,
  framework-owned vocabulary. A copied `Make` either copies that vocabulary or marks nothing,
  and the runtime would then not recognise the identity.
- **It adds no weight for consumers.** Every package that consumes a `*-spec` package is a
  plugin, and every plugin already depends on `reventless-spec`.
- **The PPX would change behaviour.** `*-spec` packages already run `reventless-ppx`, and only
  the missing dependency keeps it out of spec mode. With the dependency,
  [`ReventlessPpx.ml:796`](../../packages/reventless-ppx/src/ppx/ReventlessPpx.ml#L796) would
  inject `module Id = Reventless.Id.String` into every extension-point contract, because that
  gate checks `has_reventless_spec` only. Authorization and read-consistency injection already
  skip spec packages through `is_spec_namespace_pkg`
  ([`AuthorizationInjection.ml:287`](../../packages/reventless-ppx/src/ppx/AuthorizationInjection.ml#L287)).
  Give the Id injection the same skip in the same change (step 5).

## Spike result (2026-09-21)

**The API stands; no fallback is needed.** Tried in the tree and reverted:

- **sury-ppx finds a functor-made schema.** `include Reventless.Id.Make({let key = "orderId"})`
  in `OrderId.res`, and `orderId: OrderId.t` in a `@schema` record, compiles to
  `s.m(OrderId.schema)`, the schema `Make` marked. The same holds through `option<…>` and
  `array<…>`. The wire form is the bare string.
- **Two applications are two types.** `let x: OrderId.t = CustomerId.make("c-1")` fails with
  "This has type: CustomerId.t / But it's expected to have type: OrderId.t".
- **A chapter folder is safe.** `src/Order/OrderId.res` in the DCB ordering plugin is
  ignored by `generate-plugin` (the output is identical up to formatting), and the
  reventless-ppx leaves it alone.
- **F4 reproduced.** In `Orders`' `consumedEvent`, retyping `orderId` to `OrderId.t` replaced
  its `DcbTag.string` with `OrderId.schema`, silently, with no error. The Phase 3/4 order stands.
- **Not tried: a `*-spec` package.** None of them depends on `reventless-spec` yet, so `Make`
  cannot be reached there. Adding that dependency is Phase 4's `module Id` skip, as open
  question 5 says.

## Churn: the aggregates example (2026-09-21)

What adopting identities cost `online-shop-aggregates`, measured before migrating the DCB
example:

- **Declarations:** 4 identity files (`CategoryId`, `OrderId`, `CustomerId` in their chapters,
  `ProductId` in `catalog-spec`), and `module Id = <Identity>` on all 6 aggregates and 6 read
  models. Ordering's `CatalogProduct` and its view share catalog's `ProductId` across the plugin
  boundary.
- **Source:** 18 files touched, but **8 conversions**, every one at a seam where the framework
  routes by string: the catalog extension-point mapping (2, `makeFromString` of the delegate's
  id), the ordering extension (2), the ordering extension-point mapping (3, into the untyped
  ordering-spec contract), and the email side effect (1). Behaviours and projections needed
  none: an aggregate-sourced projection keys rows by the envelope id, which is now the view's
  own identity.
- **References:** `Order.Place` drops its `@ref("AvailableProducts") @noDcbTag`; both its
  references are derived from the types, and `Placed` / `Cancelled` gain the same references
  they previously lacked.
- **Tests:** 8 GWT files, about 20 literal bindings (`CustomerId.make("cust-1")`, made once per
  file). The assertions on the string-routed side (published contracts, `PublishAggregateCommand`
  ids) keep their literals.
- **Unchanged:** the SDL (every retyped field was already `ID` by its name), stored data, the
  GraphQL goldens. A live run on the local platform went through catalog → ordering → catalog
  (product sync, order, per-product demand) with the typed ids.
- **Left as strings, deliberately:** `ProductDemand.orderId`, since catalog cannot see ordering's
  `OrderId`, and the ordering-spec contract's fields, since its consumers have no type to hold
  them in. Typing them would mean ordering-spec declaring `OrderId`, a step for when a consumer
  needs it.

**Not found here, and worth knowing:** `Order_Place` over GraphQL never returns its
`CommandResult` on the local platform (a timeout at 30 s), while the command and its whole
cascade complete. It predates this work (reproduced with the example at the previous commit), and
is the one command whose event mapping issues a command back to its own aggregate.
