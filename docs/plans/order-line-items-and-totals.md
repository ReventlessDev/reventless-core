# Plan: a record inside an array can still be a reference and a consistency key

**Status.** Planned 2026-08-12, after a survey of the reference walk, the three
DCB tag walks, the SDL/JSON-Schema derivation and the hybrid example's ordering
slice. Nothing landed yet.

**Goal.** Let a command or event field hold a list of *records* — an order line,
a shipment row, an approval step — without the framework losing sight of the
markers on those records' fields. Concretely: `@ref` on a nested field resolves
to a picker, a DCB tag on a nested field routes the decision read and indexes
the write, and the enclosing field's GraphQL input type is nameable by a client.
Then use that capability to give the hybrid shop's orders a quantity per line
and a total.

**Non-goal.** Arbitrary nesting depth. This plan follows exactly the wrappers a
field's own value can wear — `option`, `array`, and one record inside them — and
stops there. Two levels of records inside arrays is a shape no domain here has,
and the walk it needs is a different (and much more expensive) thing than the
walk this plan writes.

**Non-goal.** Changing what a tag *means*. A nested tag is the same tag as a
flat one, with the same key and the same scope rules; only the place the walk
finds it changes.

---

## §1 — What the shop cannot say, and why

`OrderPlaced` carries `productIds: array<string>`
(`examples/online-shop-hybrid/ordering/src/Order/StateChangeSlice/PlaceOrder.res:43-49`).
There is no quantity anywhere in the ordering or catalog sources, and no total.
An order for two of something is not expressible, and what an order costs is not
recorded — even though the price is sitting in the same event log the decision
reads from.

The obvious fix is the obvious shape:

```rescript
@schema
type lineItem = {@ref("AvailableProducts") productId: string, quantity: int}

@schema
type command =
  PlaceOrder({
    @partitionTag orderId: string,
    lineItems: array<lineItem>,
    ...
  })
```

**That shape compiles and silently breaks the slice.** Three walks stop at the
first record boundary:

1. **References.** `Reference.getFieldTarget` follows the optional wrapper and
   the array element and then stops, and says so
   (`reventless/spec/src/components/Reference.res:64-66`: *"Object properties are
   not [followed]"*). `Plugin_Structure.extractReferences:173-186` asks that
   question once per top-level property, so `lineItems` reports no reference and
   the shell falls back to a text input — the same failure E13 was built to
   remove, arriving through a different door.

2. **DCB tags on the decision read.** `CommandGenerator_Callback.res:142` builds
   the decision query from `DcbTag.extractTagsFromJson(commandSchema, …)`, which
   walks `extractTagsFromProperties` — one pass over the variant's own
   properties, testing `isTagged` (scalar) and `isTaggedArray`
   (`array<@s.matches(DcbTag.string) string>`,
   `reventless/spec/src/components/DcbTag.res:270-274`). An array of *records* is
   neither. So `PlaceOrder` would read no `productId` tags,
   `PlaceOrder_Behavior`'s `availableProductIds` would stay empty, and **every
   order would be rejected with `ProductsNotAvailable`.**

3. **DCB tags on the write, and scope inference.** `extractTagsFromPropertiesExpanded`
   (`DcbTag.res:520-544`) has the same two cases, so `OrderPlaced` would be
   written with no per-product tags. And `sliceShapeFromSchemas` →
   `eventShapesOfSchema` → `idFieldsOfProperties` (`DcbTag.res:905-921`) collects
   `*Id`-shaped fields by name from the variant's own properties, so
   `DcbScopeInference` would no longer see `productId` at all and its partition
   and cross-partition derivation would shift under the slice.

None of the three fails loudly. That is the property worth naming: the shape is
accepted by the compiler, by sury, by the SDL generator and by the JSON Schema
derivation, and the first sign of trouble is a rejected order at runtime.

**One walk is already correct, and it is the one that carries the most.**
`SuryToJsonSchema.fromSchemaType` is fully recursive and re-attaches semantics at
whatever depth it finds them (`:119-181`), so the manifest's `schema` string
*already* publishes `lineItems.items.properties.productId` with its
`x-reventless-semantic-target`. And `SchemaType.fromSury` already names nested
records positionally and emits them as `input` types in mutation position
(`GraphQL_FragmentGenerator.res:51-56` with `~asInput=true` threaded from
`deriveMutationFieldFromObject:465`), so `[Ordering_PlaceOrderLineItems!]!` is
already valid generated SDL. The wire is ready; the walks are not.

**The ppx is also already correct**, provided the line item is a *named record
type* rather than an inline anonymous one. `ReferenceInference.transform_type_decl`
handles `Ptype_record` (`ReferenceInference.ml:161-172`), and so does the
`*Id` auto-tagger, so `@ref("AvailableProducts") productId: string` inside
`type lineItem` gets its `@s.matches(Reventless.Reference.to_(…))` injected the
same way it would at the top level. This is worth stating because it decides the
authoring form: **line items are a named `@schema type`, not an inline record.**

## §2 — What a nested marker is called

A flat marker is identified by a field name. A nested one needs a path, and the
path is what every consumer will key off, so pick the form once:

```
lineItems[].productId
```

`[]` for "each element of", `.` for "property of". No index — a marker applies to
every element or to none, because it lives on the element *schema*, not on a
value. A flat field keeps its bare name (`customerId`), unchanged, so nothing
that reads today's paths has to learn the new form to keep working.

**Why a path string rather than a structured field.** `fieldReference.fieldName`
is a wire field on `commandDef` / `eventDef` (`Plugin.res:158-171`) that reaches
the shell, the MCP schema generator and the baked manifest. A structured
alternative (`{field, elementOf, property}`) is a breaking change to that wire
type for every consumer including the ones that will never see a nested ref; a
path string is additive, because a consumer that splits on `.`/`[]` handles both
forms and a consumer that does not still reads flat refs exactly as today.

⚠️ **A path in `fieldName` is a widened contract, not a compatible one, for any
consumer that uses the value as a dictionary key** — `AutoUI.resolveExplicitRefs`
does exactly that (`Js.Dict.get(propsObj, r.fieldName)`), and it will simply miss
and warn. Missing is the correct degradation (text input, warning logged) but it
is a degradation, so the emission of nested refs and the consumption of them are
sequenced together in §6.

## §3 — The three walks, made path-aware

### §3.1 Tag extraction (the correctness blocker)

`DcbTag.res` gains one recursive descent, shared by both extractors:

- `isTaggedRecordArray(fieldSchema)` — an `Array` whose `additionalItems: Schema`
  is an `Object` with at least one tagged property.
- In `extractTagsFromProperties` and `extractTagsFromPropertiesExpanded`, a third
  branch for that case: for each element of the JSON array, run the existing
  per-properties extraction over the element's own properties and the element's
  own schema properties, and concatenate.

Two rules the branch must carry, both of which are silent if got wrong:

- **The tag key comes from the nested field name, not the enclosing one.**
  `lineItems[].productId` produces key `productId`, which is what makes it the
  *same* tag `CatalogProductSynced` writes. Deriving the key from `lineItems`
  (or singularising it to `lineItem`) would produce a tag key no producer ever
  writes, and the decision read would return nothing — the identical symptom to
  no tags at all, from a different cause. `resolveTagKey` already honours a
  `stringForKey` override, so an author who wants a different key still has one.
- **Duplicate keys collapse by value, not by position.** Two lines for the same
  product yield two identical `{key: "productId", value: "p1"}` tags. The
  flat-array path has never had to think about this because a multi-select does
  not repeat; a line-item list does. Dedupe within the extraction so a decision
  query does not carry the same clause twice and a written event does not carry
  a duplicate index entry.

`extractTagsFromProperties` (unexpanded) stringifies an array value into one tag
today. For a record array that form is meaningless, so the unexpanded path emits
the per-element tags too rather than a JSON blob — the two extractors agree on
record arrays even though they still differ on scalar arrays.

### §3.2 Id-field shapes for scope inference

`idFieldsOfProperties` gains the same descent, contributing
`{name: "productId", isList: true}` for `lineItems[].productId`.

`isList: true` is the correct answer and it matters: `DcbScopeInference` reasons
about *keys*, not fields, and a key reached through an array is a fan-out
whichever container it came from. Reporting `isList: false` would make the
inference treat a line-item list as a single-valued reference and derive the
wrong partition for the slice.

The inference core itself (`DcbScopeInference.res`) is unchanged — it is
deliberately schema-agnostic and takes `idField {name, isList}`, which is
exactly what the descent produces. That the boundary type needs no change is
evidence the boundary was drawn in the right place; say so in the module rather
than only here.

### §3.3 References

- `Reference.res` gains `collectFieldTargets: (string, S.t<unknown>) =>
  array<(string, target)>` — the field name plus its schema, returning
  `(path, target)` pairs. The existing `getFieldTarget` stays exactly as it is,
  including its docstring, because the *question it answers* is still the right
  question for a caller that wants "does this field itself reference something".
  Add a sentence pointing at the new function rather than editing the old
  reasoning; the reasoning is not wrong, it was answering a narrower question.
- `Plugin_Structure.extractReferences` uses the new function. It already runs
  over commands and events from one place (`:173-186`), which is what stops one
  of them learning about nesting and the other not.

## §4 — Naming the nested input type on the wire

A client that sends a mutation declares its variables' types. For
`lineItems: [Ordering_PlaceOrderLineItems!]!` the client needs the string
`Ordering_PlaceOrderLineItems`, and it cannot derive it from JSON Schema — the
name comes from `SchemaType.fromSury`'s positional rule
(`SchemaType.res:120-136`), which is a server-side convention.

**Publish it.** `SuryToJsonSchema` emits `x-reventless-graphql-input: "<Name>"`
on an `ObjectRef`'s JSON Schema, at whatever depth it occurs — the array item
schema for a record array, the field schema for a plain nested record. The name
is taken from the same `ObjectRef(name, _)` the SDL generator uses, so there is
one source and it cannot drift.

**This fixes a live bug, not only the new shape.** A command field of *any*
object type is mistyped by the shell today: it maps JSON-Schema `"object"` to
GraphQL `String` (`jsonTypeToGql`, `_ => "String"`), so `PlaceOrder`'s
`deliveryWindow: DateRangeInput` and `AddProduct`'s `price: MoneyInput` are
declared as `$deliveryWindow: String!` / `$price: String!` against an SDL that
says otherwise. **Verify this against the running local example before building
on it** — the failure mode is a GraphQL validation error at submit time, which
is loud, so it is possible some other path is compensating. Whether or not it
reproduces, publishing the name is what the line-item work needs and what makes
a client's job derivable rather than conventional.

Semantic composites already carry a canonical name (`SchemaType.canonicalName`)
and take the `Input` suffix in input position (`GraphQL_FragmentGenerator.res:76`);
emit the suffixed form, so the published string is the one a client can paste
into a variable declaration without knowing the rule.

## §5 — The example: an order that says how many and what it cost

With §3 landed, the domain change is small and entirely conventional.

**`PlaceOrder`** (`ordering/src/Order/StateChangeSlice/PlaceOrder.res`)

- `@schema type lineItem = {@ref("AvailableProducts") productId: string, quantity: int}`
- command: `productIds: array<string>` → `lineItems: array<lineItem>`
- `consumedEvent` gains the price: `CatalogProductSynced({productId, name, price})`
  and a new arm `CatalogProductPriceChanged({productId, price})`. Both already
  exist in the Ordering log — `SyncCatalogProduct` writes them
  (`ordering/src/CatalogProduct/StateChangeSlice/SyncCatalogProduct.res:20-29`) —
  so **pricing an order needs no cross-plugin read and no read-model query from a
  behaviour.** This is the whole reason totals are cheap here, and it is worth a
  comment in the slice: the ordering side already shadows what it needs to decide.
- `error` gains `OrderIsEmpty` and `InvalidQuantity({productId, quantity})`.
- event `OrderPlaced` gains `lines: array<orderLine>` and `total: Reventless.Money.t`,
  where `orderLine = {productId, name, quantity, unitPrice, lineTotal}`.

**`PlaceOrder_Behavior`** folds `{productId → (name, price)}` instead of a bare
id list, rejects an empty list and any non-positive quantity, **merges duplicate
product ids into one line** (summing quantities — an order for the same thing
twice is one line of two, and merging here is what keeps the read side and the
extension point from having to think about it), prices each line and sums the
order.

Three decisions to record in the behaviour, because each has a wrong answer that
looks right:

- **Price at placement, from the log.** The unit price copied onto the event is
  the one the decision model held. A later `CatalogProductPriceChanged` does not
  rewrite a placed order — which is the correct answer for a shop and the reason
  the total belongs on the event rather than in the projection.
- **A mixed-currency order is refused, not silently summed.** `Money.add` already
  returns `result` for exactly this (`Money.res:178-189`); surface it as an error
  rather than unwrapping it.
- **`Money` has no multiply.** Add `Money.times(m, ~by: int)` beside `add`/`sum`
  in `reventless/spec/src/semantic/Money.res`, checked the same way `add` checks
  its currency and `validateAmount` checks wholeness. Do not compute
  `amount *. float(qty)` at the call site — that is the exact arithmetic the
  module exists to own.

**Keep `productIds` on the event.** `OrderPlaced` carries **both**
`lines: array<orderLine>` and `productIds: array<string>` (derived by the
behaviour from the merged lines). It is redundant on purpose:

- `Orders_ExtensionPointMapping` decomposes `productIds` into per-product
  `ItemOrdered` events (`ordering/src/ExtensionPoint/Orders_ExtensionPointMapping.res:21-27`)
  and `CancelOrder` consumes `OrderPlaced({productIds})` — both keep working
  untouched.
- The public extension point contract (`ordering-spec`) does not change, so
  Catalog does not have to be redeployed in lockstep with Ordering to make the
  shop show quantities. A cross-plugin contract change is a separate decision
  from a domain enrichment, and this plan does not need one.
- It is a second, independent carrier of the `productId` tags, which means the
  slice keeps working even if §3.1 has a gap. That is a crutch, so §8 asserts the
  nested tags directly rather than through the slice's behaviour.

**`Orders` view and projection** gain `lines`, `total`, and `itemCount` (the
summed quantity — a shopper's "how many things is this", and the one number a
list view can show in a column). `productIds` stays on the state as-is.

**`ProductDemand`** currently counts orders (`orderCount`, incremented once per
`ItemOrdered`). With quantities the honest counter is units. Extending
`Orders_ExtensionPoint.ItemOrdered` with `quantity` *is* a public contract
change, so it is scoped **out** of this plan and recorded in §9; `orderCount`
keeps counting orders and its docstring is corrected to say so, since today it
reads as if it were demand.

**Seed data.** `seed-data/src/DemoData.res` generates 150 orders from
`productIds`; it produces `lineItems` with a small weighted quantity instead
(mostly 1, occasionally 2–3, so the totals in the demo are not all identical).
The seed is deterministic (`Seed.Random.make(~seed=0x5eed)`), so this changes
every seeded order — expected, and the reason §8 asserts a known total rather
than a snapshot.

**Tests.** `PlaceOrder_GWT` (all cases restated in the new command shape, plus
empty-order, non-positive-quantity, duplicate-merge and mixed-currency),
`Orders_GWT`, `AvailableProducts_GWT`, `OrderingFlow_GWT`, `HybridFlow_GWT`. New
framework tests in `reventless/spec/tests` for the three walks, and the
decisive one is **the tag walk, asserted directly**: given a command JSON with a
two-line `lineItems`, `extractTagsFromJson` returns both `productId` tags with
the right key. Every other assertion in this plan can pass with a broken tag walk
as long as `productIds` is still on the event.

**Goldens.** `examples/online-shop-hybrid/schema/domain-api.graphql` moves
(`Ordering_PlaceOrder` args, the new input type, the `Ordering_Orders` fields).
Refresh with `pnpm run check:graphql:update` in the same commit as the change
that moved it — the schema diff is the review artefact.

## §6 — Easy wins, each independently landable

Ordered by value to the shopper per unit of work. Each stands alone; none gates
another.

- **W1 — `Int` survives to the wire.** `SchemaType` has no integer case
  (`:97 | Number(_) => ScalarNumber`), so every `int` is `Float!` in SDL and
  `"type":"number"` in JSON Schema — `ProductDemand.orderCount: Float!` in the
  golden today, and `quantity` would join it. sury carries the fact
  (`Number({format: numberFormat})`), it is simply dropped. Add `ScalarInt`,
  map it to `Int` / `"integer"`. Touches the goldens. *Small; pure framework.*
- **W2 — the category has a name in the shop.** `Products.state` carries
  `categoryId` and no name, so a shopper sees an opaque id and a `@groupBy` on it
  would section the shop by `cat-03`. `AddProduct` already consumes
  `CategoryAdded({categoryId})` — take the name too, emit `categoryName` on
  `ProductAdded`, carry it on `Products.state` with `@groupBy`. Captured at
  placement, so a later rename does not propagate; that is the event-sourced
  answer and belongs in a comment, not in a projection fan-out (a projection
  keyed by `productId` cannot rewrite every row of a renamed category — the
  reason the tempting version of this is not the cheap one). *Small; example only.*
- **W3 — an order shows what was ordered.** Falls out of §5: `orderLine.name` is
  captured at placement, so "My Orders" reads *Fathom Dock 4-Port × 2* instead of
  a uuid. No extra work beyond §5; listed because it is the largest visible
  change and should be named in acceptance.
- **W4 — the list view says how many.** `@summary` on `Orders.itemCount` and
  `Orders.total`, `@hidden` on `Orders.productIds` (the redundant tag carrier
  from §5 — correct on the event, noise in a grid). Schema-only, no runtime
  change. *Trivial; example only.*
- **W5 — `@live(true)` on `Orders`.** An order list is operational, an
  `AutoShipOrder` flips a row while the shopper watches, and the hint is one
  type-level annotation. *Trivial; example only.*
- **W6 — refuse an empty order.** Part of §5's behaviour, called out because it
  is the one validation a shopper can trip today: `PlaceOrder` with `productIds:
  []` currently succeeds and produces an order for nothing.

**Considered and not taken**, with the reason, so they are not re-proposed:

- *Product images in the checkout picker.* `AvailableProducts` has no `imageUrl`,
  so the picker is text-only. Carrying one would change the public
  `Products_ExtensionPoint` contract and cross a `@storageRef` store boundary
  between plugins — real cost — and `RefCombobox` renders a label, so the picker
  would look identical afterwards. Not worth it until the picker can show a
  thumbnail.
- *Hiding archived categories from the shop.* `Categories` shows `archived: bool`
  rows to shoppers. Deleting them from the projection would also remove them as
  `@ref("Categories")` targets for admin `AddProduct`, which is a regression for
  the other persona reading the same view. Needs the visible/referenceable split
  applied to *rows* rather than components, which is a larger idea than a win.
- *Stock and availability.* A real reservation is the canonical DCB
  demonstration and deserves its own plan; bolting an unreserved `inStock: bool`
  onto the product view would demonstrate the opposite of what the framework does
  well.

## §7 — What this must not break

- **`AvailableProducts` stays `AllowAuthenticated`.** It is `Internal` in the nav
  and read at runtime to populate the picker; an `AllowGroups(["Admin"])` there
  would break checkout invisibly.
- **Owner-scoped reads are in flight in this tree.** `Owner.res`,
  `OwnerScope.res` and the `QueryDbListQuery` / sqlite / Postgres push-downs are
  modified and uncommitted. `Orders.state` is where an `@owner` marker lands, and
  this plan edits the same record. Land or park that work before starting §5, and
  do not renumber or reshape `Orders.state` fields while it is open.
- **Do not "fix" `getFieldTarget` by making it descend.** Its contract — the
  reference a *field* declares — is relied on where attributing a nested marker
  to the enclosing field would name the wrong field. Descent is a new function.
- **The unexpanded and expanded tag extractors must agree on record arrays.**
  They deliberately differ on scalar arrays; a reader who assumes the difference
  generalises will write a subtle bug. State the agreement where both are
  defined.

## §8 — Acceptance

Framework, provable by unit test with no platform running:

1. `DcbTag.extractTagsFromJson` over a `PlaceOrder` command JSON with lines for
   `p1` and `p2` returns exactly `productId=p1`, `productId=p2` — and returns one
   `productId=p1` for a command with two lines of `p1`.
2. `extractTagsFromJsonExpanded` over the emitted `OrderPlaced` returns the same
   set.
3. `Plugin_Structure.extractReferences` on the `PlaceOrder` command variant
   returns `{fieldName: "lineItems[].productId", entity: "AvailableProducts"}`,
   and a flat `@ref` field in the same variant still returns its bare name.
4. `sliceShapeFromSchemas` for `PlaceOrder` reports
   `{name: "productId", isList: true}` in `command`, and `DcbScopeInference.infer`
   over the hybrid slice set derives the same partition per slice as it does
   before the change (a diff here means the descent changed the graph, not just
   the walk).
5. The `Ordering_PlaceOrder` mutation's `lineItems` argument in the refreshed
   golden is `[Ordering_PlaceOrderLineItems!]!`, that input type is declared, and
   the manifest's command schema carries
   `x-reventless-graphql-input: "Ordering_PlaceOrderLineItems"` on the item.

End to end against `platform-local`:

6. Placing a two-line order (2 × A, 1 × B) succeeds, and the resulting row shows
   both product **names**, `itemCount: 3`, and a total equal to
   `2·price(A) + price(B)` — asserted as an exact figure, not as "a total is
   present".
7. Placing an order for an unsynced product still fails with
   `ProductsNotAvailable` — the decision read still works, which is the
   assertion that the nested tags are genuinely being used and not compensated
   for by `productIds`.
8. An empty `lineItems`, a zero quantity, and a negative quantity are each
   refused with their own error.
9. An `Express` order still flips Placed → Shipped by itself, and Catalog's
   `ProductDemand` still increments — the extension point is untouched, and this
   is the check that proves it.

## §9 — Deferred, recorded so it is not re-derived

- **Quantity through the extension point.** `ItemOrdered({productId, orderId,
  customerId})` gaining `quantity` would let `ProductDemand` count units rather
  than orders. It is a public contract change between two independently
  deployable plugins and belongs with whatever else next changes that contract.
- **Nested markers at depth ≥ 2.** Out of scope by §0; the path vocabulary
  (`a[].b.c`) already expresses it, so extending the walk later is additive.
- **`@owner` on a nested field.** The same descent question, for the marker E4
  introduces. Not needed by any shape here — an owner is a property of the row,
  not of a line — but the walk this plan writes is the one that would answer it.
