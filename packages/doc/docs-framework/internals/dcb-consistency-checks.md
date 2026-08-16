---
title: DCB Consistency Checks
---

# DCB Consistency Checks

A `StateChangeSlice` writes to a shared `DcbEventLog` under **optimistic concurrency control (OCC)**: it reads the events relevant to a decision, decides, then appends the new events *conditionally* — the append commits only if nothing relevant changed between the read and the write. No locks are held.

This page traces one command end-to-end through the three stages that make that check work, using real slices from the `online-shop-hybrid` example:

1. **Build the query** from the command (which events are relevant?).
2. **Read the decision model** by running that query against the event log.
3. **Append conditionally**, turning the query into a set of consistency *fences* that DynamoDB enforces atomically.

```d2
cycle: {
  shape: sequence_diagram
  Topic: "Command Topic" { class: command-topic }
  Slice: Slice { class: state-change-slice }
  Log: DcbEventLog { class: dcb-event-log }

  Topic -> Slice: command { class: command-flow }
  Slice -> Log: "read (query)"
  Log -> Slice: events
  Slice -> Slice: "evolve → state"
  Slice -> Slice: "decide → events"
  Slice -> Log: "append (query, after)" { class: event-flow }
  Log -> Slice: "Ok | Conflict"
}
```

The orchestration lives in `StateChangeSlice_Callback.handleSingleCommand`; the query construction in `DcbTag.buildQueryFromCommand`; the fence transaction in the storage adapter (`DcbEventLogStorage_DynamoDb_Runtime.buildConditionalTransactItems`).

## Stage 1 — Building the query from the command

The slice does not hand-write a query. `DcbTag.buildQueryFromCommand(~eventTypes, ~schema, ~value)` derives it from the command value and its schema:

- **`eventTypes`** — the event types the slice consumes, taken from its `consumedEvent` schema, then **narrowed per clause** to the types whose *produced* tag set (looked up in the shared event-log schema) can actually carry that clause's tag(s). A type that can never carry a clause's tag is dropped from that clause — a vacuous (type, tag) pairing matches nothing, so results are unchanged.
- **tags** — extracted from the command's DCB-tagged fields (`@s.matches(DcbTag.string)`, injected by the `@@reventless.spec` ppx on `*Id` fields). Fields marked `@noDcbTag` are excluded.

A query is an array of **clauses** (`queryItem`s). Within a clause, tags are AND-ed; across clauses, they are OR-ed. The clause shape is chosen automatically from the schema:

| Command shape | Query mode | Hybrid example |
|---|---|---|
| Scalar tags only | one AND clause | `AddProduct` |
| A tagged `array<string>` field | one OR clause per element | `PlaceOrder` |
| Two or more scalar tags | one AND clause with multiple tags (composite) | `RecordProductDemand` |
| A `@crossPartition` scalar tag | its own single-tag OR clause (cross-partition read) | `OrderProduct` |

### Single-entity — `AddProduct`

```rescript
type command = AddProduct({ productId: string, name: string, description: string, price: float })
type consumedEvent = ProductAdded
```

`productId` is the only tag; `name`/`description`/`price` are untagged payload. The command has no tagged array, so the query is a single AND clause:

```
AddProduct({ productId: "prod-1", … })
→ [ { eventTypes: ["ProductAdded"], tags: [ productId:prod-1 ] } ]
```

### Cross-entity — `PlaceOrder`

```rescript
type command =
  PlaceOrder({ @partitionTag orderId: string, @noDcbTag customerId: string, productIds: array<string> })
type consumedEvent =
  | OrderPlaced({ orderId: string })
  | CatalogProductSynced({ productId: string })
```

`productIds` is a tagged array, so the command references many entities at once. The query expands to **one OR clause per element**, plus the scalar `orderId` clause. `customerId` is `@noDcbTag`, so it never appears:

```
PlaceOrder({ orderId: "ord-1", customerId: "cust-9", productIds: ["prod-1", "prod-2"] })
→ [ { eventTypes: ["OrderPlaced"],                      tags: [ orderId:ord-1   ] },
    { eventTypes: ["OrderPlaced","CatalogProductSynced"], tags: [ productId:prod-1 ] },
    { eventTypes: ["OrderPlaced","CatalogProductSynced"], tags: [ productId:prod-2 ] } ]
```

Note the `orderId` clause lists only `OrderPlaced` — `CatalogProductSynced` is dropped because it can never carry an `orderId` tag (the per-clause narrowing above). The `productId` clauses keep **both** types: `CatalogProductSynced` is partitioned by `productId`, and `OrderPlaced` carries `productId` as a *secondary* tag, so it is a legitimate (cross-partition) carrier — clauses list only types whose produced tag set carries the clause's tag.

Each clause carries a **single** tag — this matters in Stage 2: a single-tag clause is read as one partition.

### Multi-tag composite — `RecordProductDemand`

```rescript
type command =
  | RecordDemand({ @partitionTag productId: string, orderId: string })
  | RevokeDemand({ @partitionTag productId: string, orderId: string })
```

Both `productId` and `orderId` are tags (no array), so the query is a single clause with **two** tags AND-ed together — the consistency boundary is the exact `(product, order)` pair:

```
RecordDemand({ productId: "prod-1", orderId: "ord-1" })
→ [ { eventTypes: ["ProductDemandRecorded","ProductDemandRevoked"],
      tags: [ productId:prod-1, orderId:ord-1 ] } ]
```

### Cross-partition single-tag — `OrderProduct`

:::info Capability
`@crossPartition` is **implemented**. None of the other slices above use it — they read partition-scoped by default; `@crossPartition` opts a tag into a cross-partition (secondary-tag) read. The `OrderProduct` slice below is illustrative (no example plugin ships it yet), but the annotation and the read/fence routing it relies on are live.
:::

Suppose a customer may order at most *N* units of a given product — **across all their orders, however many they place**. Enforcing that means aggregating one customer's purchases of one product, and a customer's orders are scattered across many `orderId` partitions. So the read keys on **`customerId`**, which a single order carries as a *secondary* tag — a cross-partition read:

```rescript
type command =
  OrderProduct({
    @partitionTag orderId: string,
    @crossPartition customerId: string,   // read THIS customer's whole history, across partitions
    productId: string,                     // payload — which product to cap (filtered in the fold)
    quantity: int,                         // payload — units in this order (summed in the fold)
  })
type consumedEvent =
  ProductOrdered({ productId: string, quantity: int })   // the fields evolve needs to sum the cap
type event =
  ProductOrdered({
    @partitionTag orderId: string,
    @crossPartition customerId: string,
    productId: string,
    quantity: int,
  })
```

Only `orderId` and `customerId` are tags; `productId`/`quantity` are untagged payload. So the command builds **two single-tag clauses** (a `@crossPartition` tag fans out into its own clause, like the partition tag — not AND-ed into a composite):

```
OrderProduct({ orderId: "ord-7", customerId: "cust-9", productId: "prod-1", quantity: 3 })
→ [ { eventTypes: ["ProductOrdered"], tags: [ orderId:ord-7    ] },   // partition read — already placed this order line?
    { eventTypes: ["ProductOrdered"], tags: [ customerId:cust-9 ] } ]  // cross-partition read — all of cust-9's orders
```

The `customerId` clause is a single tag, but because `customerId` is `@crossPartition` it is **not** a partition lookup:

- **Stage 2** routes it to the `tag_customerId` **GSI**, returning every `ProductOrdered` by `cust-9` across all `orderId` partitions. `evolve` keeps the ones with `productId == "prod-1"` and sums their `quantity`; `decide` rejects if that sum + `3 > N`. (A plain partition read would hit the empty `customerId:cust-9` partition, sum zero, and the cap would never fire.)
- **Stage 3** advances `fence#customerId:cust-9` on **every** `ProductOrdered`, so two orders **by the same customer** racing against the cap conflict and one retries — the cap holds under concurrency. Crucially, the fence is on `customerId`, so only *that customer's* concurrent orders serialize; different customers never contend.

See [Reading by a secondary tag](#reading-by-a-secondary-tag--cross-partition-reads) for the read-routing and fence detail.

A few design points this example makes concrete:

- **The product is narrowed in the fold, not the query.** Reading by the *pair* `{customerId, productId}` would be a composite **exact-set** match — keyed on the event's full tag set (including `orderId`, per the composite rule in Stage 2 above), so it can't express "all of `cust-9`'s events for `prod-1`". So you read by `customerId` cross-partition and filter the product in `evolve`. Not every constraint is a tag.
- **Read the lower-degree side.** Reading `customerId` (a handful of orders per customer) and filtering the product is far cheaper than reading `productId` cross-partition (every order of a popular product) and filtering the customer — and it also puts the fence on the low-contention key.
- **Contrast with `PlaceOrder` above**, where `customerId` is `@noDcbTag` (pure payload) and `productId` is read *partition-scoped*. A field that's untagged payload in one slice becomes a cross-partition read key in another when an invariant needs to aggregate by it. Because scope is a **global property of the tag key**, making `customerId` cross-partition applies to every producer of it — the global trade-off in [Why the opt-in must be explicit](#why-the-opt-in-must-be-explicit) (here a cheap one: same-customer concurrency is rare).

## Stage 2 — Reading the decision model

The callback runs `dcbEventLog.readStream(~query)` and folds the events into a **decision model** with the slice's `evolve` function, starting from `initialState` — one `evolve(state, event)` call per event. It also records the **head position** (the latest position seen) as `after`. Only once the fold is complete is `decide(state, command)` called. Each clause maps to a physical read by its tag count:

| Clause | Physical read | Consistency |
|---|---|---|
| One tag | base-table **partition** query on `id = "<key>:<value>"` | strongly consistent |
| Two+ tags | **composite GSI** (`tag_composite`) query | eventually consistent |
| No tags (type-only) | table scan filtered by event type | eventually consistent |

Two consequences worth internalising:

- **A single-tag read is partition-scoped.** Events are stored in the partition of their *primary* tag (`id="<key>:<value>"`). So `[productId:prod-1]` returns only events *partitioned by* `productId` (e.g. `CatalogProductSynced`). An event that merely *carries* `productId` as a secondary tag — `OrderPlaced`, partitioned by `orderId` — lives in a different partition and is not returned. Slices read by the tag that the events they want are *partitioned by*.
- **Composite reads match the exact tag set.** A `[productId, orderId]` clause matches events tagged with exactly that pair.

For `PlaceOrder` the three clauses become three partition reads, folded together:

- `orderId:ord-1` → prior `OrderPlaced` for this order → "already placed?"
- `productId:prod-1`, `productId:prod-2` → `CatalogProductSynced` per product → "available?"

`decide` then returns `OrderAlreadyPlaced`, `ProductsNotAvailable`, or `Ok([OrderPlaced{…}])`.

Note the `productId` reads here are deliberately **partition-scoped**: `PlaceOrder` wants `CatalogProductSynced` (partitioned by `productId`) and *tolerates* not seeing sibling `OrderPlaced` (which carry `productId` only as a secondary tag). So `productId` is **not** `@crossPartition`, and scope inference agrees: it promotes a foreign reference to a cross-partition read **only when the command carries it as a scalar** (which must be fanned out of the composite clause). `PlaceOrder` reads `productId` via the **array** `productIds`, which already auto-fans into per-element partition-scoped clauses — so inference leaves it partition-scoped. (A *scalar* foreign reference like `AddProduct`'s `categoryId` is the opposite case: it is fanned cross-partition automatically. See [Reading by a secondary tag](#reading-by-a-secondary-tag--cross-partition-reads).)

### Reading by a secondary tag — cross-partition reads

:::info Default is partition-scoped
Every single-tag read is partition-scoped **by default** (`PartitionScoped`). `@crossPartition` opts a specific tag key into a cross-partition read. This section documents how it works. Note that scope inference (`DcbScopeInference`) now derives cross-partition scope for **scalar cross-entity references** automatically (a slice reading another entity's lifecycle by its id), so the explicit annotation below is reserved for the case inference can't see — the **M:N capacity** read, where a slice reads its *own* event type by a secondary key across all partitions.
:::

A single-tag read being partition-scoped (above) blocks the **canonical M:N decision**. Take course subscription: a `StudentSubscribed` event ties two entities and must enforce two invariants on subscribe — *course not full* (read by `courseId`) and *student not over-enrolled* (read by `studentId`). The event can be partitioned by only one tag, so the other read is inherently cross-partition.

The annotation goes on the **command** and the produced **`event`** — exactly where `@partitionTag` already lives, and consistently across both — never on `consumedEvent` (which carries no tag annotations):

```rescript
// command — its tagged fields build the read query
@schema type command =
  | SubscribeStudent({
      @partitionTag courseId: string,      // → clause [courseId:C1] — partition read: course full?
      @crossPartition studentId: string,   // → clause [studentId:S1] — cross-partition read: over-enrolled?
    })

// produced event — drives partitioning, GSI indexing, and fence scope
@schema type event =
  | StudentSubscribed({
      @partitionTag courseId: string,
      @crossPartition studentId: string,
    })
```

Each tag becomes its **own single-tag clause** (the partition tag and each cross-partition tag fan out separately — they are *not* AND'd into one composite exact-pair clause):

- Read by `courseId:C1` → base-table partition query (it *is* the partition tag) → all of the course's subscriptions. ✓
- Read by `studentId:S1` → `studentId` is `@crossPartition`, so the read routes to the `tag_studentId` **GSI** (which indexes the tag across every `courseId` partition) → all of the student's subscriptions. ✓ Without the annotation, this read hits the empty `studentId:S1` base-table partition and the over-enrolment check silently always passes.

Correspondingly, the fence (Stage 3) for a cross-partition tag must **advance on every carrier** (an `Update`, like a composite tag — not the `ConditionCheck` a partition-scoped secondary read gets), or OCC would miss a concurrent secondary-`studentId` writer. The annotation on the command drives the read routing; the same annotation on the produced event drives the fence scope — keeping fence-scope = read-scope per tag.

#### Why the opt-in must be explicit

The framework *can* tell that a tag isn't the partition tag of a given event type — so why not auto-promote every secondary-tag read to a cross-partition one? Because detecting "not the partition tag" is not the same as knowing the slice *wants* the cross-partition fold, and guessing wrong is expensive and silent:

- **Intent isn't derivable.** `PlaceOrder` reads by `productId` to check availability from `CatalogProductSynced` (for which `productId` *is* the partition tag — a partition read is correct). `OrderPlaced` also carries `productId` as a secondary tag, but `PlaceOrder` deliberately *ignores* sibling orders — it tolerates the over-read, it doesn't want it. The same tag key is "the partition tag I want" for one type and "a secondary tag I ignore" for another; types and tags alone can't distinguish *want* from *tolerate*.
- **The fence is global, so the cost is global.** Read-scope must equal fence-scope, so auto-promoting `productId` would force *every* `OrderPlaced` to advance `fence#productId` — serializing every order for a popular product on one fence and paying extra transactional WCU. The fence is advanced by **writers**, not readers, so scope can't be per-slice: opting one tag into cross-partition changes contention for every writer of it. That is a deliberate trade-off the developer must declare, which is why the scope "must agree across every event type that carries the tag".

So the default is `PartitionScoped` (cheap, narrow fence, secure-by-default) and a tag opts **in** to `CrossPartition`. Inverting the default would make the high-contention path implicit and silently degrade slices like `PlaceOrder`.

## Stage 3 — The conditional append (consistency fences)

If `decide` produces events, the callback appends them with `~condition={ query, after }`. The DynamoDB adapter turns that condition into **fence sentinels** carried on a single `TransactWriteItems` alongside the event writes — so the whole append is atomic.

A fence is one item per tag value: `id="fence#<key>:<value>", position="FENCE"`, holding one position attribute **per event type** — `pos#<eventType>` — each the newest position of that type written into the tag's partition. The append asserts, per relevant tag, that no event **of a type the slice reads** has advanced past the `after` the slice observed:

```
(attribute_not_exists(pos#<consumedTypeA>) OR pos#<consumedTypeA> <= :after)
  AND (attribute_not_exists(pos#<consumedTypeB>) OR pos#<consumedTypeB> <= :after)
  AND …
```

and advances `pos#<producedType>` for the types it writes. If any assertion fails the transaction is cancelled → surfaced as `Conflict`.

Scoping the check to the **consumed** types is what makes the OCC mirror the read query's event-type filter: a slice reading only a *subset* of a partition's event types — e.g. `ChangeProductName`, which reads `ProductAdded`/`ProductNameChanged` but not `ProductPriceChanged` — no longer conflicts when a *sibling* type (a price change) advances the partition. Per-type fence attributes keep the DynamoDB check identical to the local backends' true query semantics (which filter the append condition by event type as well as tag).

### How each query tag becomes a fence item

The adapter classifies each tag of the condition. The guiding rule is **fence-scope = read-scope**: a tag's fence is *advanced* only by writes into the partition that a read of that tag would observe — otherwise a secondary tag shared across partitions would conflict every later writer that merely carries the same value. Within that, each item is scoped to the relevant event types (consumed for the check, produced for the advance).

| Tag role in the append | Fence item | Effect |
|---|---|---|
| The written event's **partition** tag | conditional `Update` | assert each `pos#<consumedType> ≤ after` **and** advance `pos#<producedType>` |
| A **single-tag** clause that is *not* the partition tag (a partition-scoped secondary read) | `ConditionCheck` | assert each `pos#<consumedType> ≤ after` only — never advance |
| A **single-tag** clause on a `CrossPartition` tag (see [above](#reading-by-a-secondary-tag--cross-partition-reads)) | conditional `Update` | assert **and** advance (read crosses partitions, so OCC needs the bump) |
| A tag in a **multi-tag (composite)** clause | conditional `Update` | assert **and** advance (composite reads cross partitions, so OCC needs the bump) |
| An untagged field (e.g. `@noDcbTag customerId`) | — | no fence at all |

**Composite partition keys are the exception to "one fence per tag".** When the partition is a `@compositePartitionTag` key (several fields joined into one composite value), the whole multi-tag clause collapses to a **single** fence on that composite value — `fence#<compositeValue>`, checked **and** advanced as one item — rather than one fence per member. This mirrors the read exactly (a composite partition is read as one `tag_composite` exact match) and keeps the fence as selective as the entity: fencing each member separately would put a shared fence on every low-cardinality member (e.g. a common prefix field), needlessly serialising *distinct* composite entities that merely share a member value.

### First writes — the folded creation guard

When the decision-model read returned nothing, `after` is absent: there is no fence position to check against. A plain append would let two concurrent first-writers both create the same entity. Instead, at `after=None` the **partition-tag fence** becomes a conditional `Update` gated on `attribute_not_exists(pos#<type>)` over the slice's consumed **and** produced types, advancing `pos#<producedType>`. Two concurrent first-writers of the same `(producedType, partition)` collide on `attribute_not_exists(pos#<producedType>)`, so at most one commits; the loser conflicts and retries.

Because the guard lives in the per-type attribute, it never collides with a *different* type already in the partition — a slice that reads only a subset of a partition's event types (and so legitimately sees nothing) is not falsely blocked. This **folds the creation guard into the fence**: there is no longer a separate `create#…` sentinel row (earlier versions used one because a scalar `lastPosition` could not distinguish event types).

### Worked example — `PlaceOrder` transaction

For `PlaceOrder({orderId:"ord-1", customerId:"cust-9", productIds:["prod-1","prod-2"]})`, with the two products already synced (so `after` is present), the produced `OrderPlaced` is tagged `[orderId:ord-1, productId:prod-1, productId:prod-2]` and partitioned by `orderId`. The append carries:

| Transact item | Why |
|---|---|
| `Put` `OrderPlaced` at `id="orderId:ord-1"` | the new event |
| `Update` `fence#orderId:ord-1` — check `pos#OrderPlaced ≤ after`, advance `pos#OrderPlaced` | `orderId` is the partition tag |
| `ConditionCheck` `fence#productId:prod-1` — check `pos#CatalogProductSynced ≤ after` | secondary read — assert the product wasn't re-synced under us |
| `ConditionCheck` `fence#productId:prod-2` — same | same |

`customerId` is untagged, so it contributes no fence. The two `ConditionCheck`s preserve the availability decision (a concurrent re-sync of a product would advance its `pos#CatalogProductSynced` and conflict this order) **without** advancing `fence#productId:*` — so a *different* order of the same product does not spuriously conflict.

### Worked example — `RecordProductDemand` transaction

`RecordDemand({productId:"prod-1", orderId:"ord-1"})` reads a composite clause, so both tags are part of the consistency boundary. The produced `ProductDemandRecorded` is partitioned by `productId`, and the append carries:

| Transact item | Why |
|---|---|
| `Put` `ProductDemandRecorded` at `id="productId:prod-1"` | the new event |
| `Update` `fence#productId:prod-1` — check `pos#ProductDemandRecorded ≤ after`, advance it | composite tag |
| `Update` `fence#orderId:ord-1` — same | composite tag |

Both tags check **and** advance, because a composite read can match events across partitions.

## Retry on conflict

`handleSingleCommand` wraps the read-decide-append cycle in a retry loop (3 attempts). A `Conflict` means a relevant fence moved between the read and the append: the slice re-reads the now-current decision model, re-decides, and re-appends. Because well-behaved commands are idempotent (a command that would change nothing returns `Ok([])`), a retry that discovers the work is already done simply commits nothing.

## Source of truth

| Concern | Module |
|---|---|
| Query construction | `reventless-spec` · `DcbTag.buildQueryFromCommand`, `extractTags`, `extractTagsExpanded` |
| Read / decide / append / retry | `reventless-core` · `StateChangeSlice_Callback.handleSingleCommand` |
| Fence transaction, partition derivation, folded creation guard | `reventless-aws` · `DcbEventLogStorage_DynamoDb_Runtime.buildConditionalTransactItems` |

See also [DCB (Dynamic Consistency Boundary)](../architecture/dcb.md) for how slices, the command topic and the event log are wired together at deploy time.
