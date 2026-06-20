---
title: DCB Consistency Checks
draft: false
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

- **`eventTypes`** — the event types the slice consumes, taken from its `consumedEvent` schema. Every query clause filters to these types.
- **tags** — extracted from the command's DCB-tagged fields (`@s.matches(DcbTag.string)`, injected by the `@@reventless.spec` ppx on `*Id` fields). Fields marked `@noDcbTag` are excluded.

A query is an array of **clauses** (`queryItem`s). Within a clause, tags are AND-ed; across clauses, they are OR-ed. The clause shape is chosen automatically from the schema:

| Command shape | Query mode | Hybrid example |
|---|---|---|
| Scalar tags only | one AND clause | `AddProduct` |
| A tagged `array<string>` field | one OR clause per element | `PlaceOrder` |
| Two or more scalar tags | one AND clause with multiple tags (composite) | `RecordProductDemand` |

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
→ [ { eventTypes: ["OrderPlaced","CatalogProductSynced"], tags: [ orderId:ord-1   ] },
    { eventTypes: ["OrderPlaced","CatalogProductSynced"], tags: [ productId:prod-1 ] },
    { eventTypes: ["OrderPlaced","CatalogProductSynced"], tags: [ productId:prod-2 ] } ]
```

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

## Stage 3 — The conditional append (consistency fences)

If `decide` produces events, the callback appends them with `~condition={ query, after }`. The DynamoDB adapter turns that condition into **fence sentinels** carried on a single `TransactWriteItems` alongside the event writes — so the whole append is atomic.

A fence is one item per tag value: `id="fence#<key>:<value>", position="FENCE", lastPosition=<position>`. Its `lastPosition` is the newest position written into that tag's partition. The append asserts, per relevant tag, that the fence has not advanced past the `after` the slice observed:

```
attribute_not_exists(lastPosition) OR lastPosition <= :after
```

If any assertion fails the transaction is cancelled → surfaced as `Conflict`.

### How each query tag becomes a fence item

The adapter classifies each tag of the condition. The guiding rule is **fence-scope = read-scope**: a tag's fence is *advanced* only by writes into the partition that a read of that tag would observe — otherwise a secondary tag shared across partitions would conflict every later writer that merely carries the same value.

| Tag role in the append | Fence item | Effect |
|---|---|---|
| The written event's **partition** tag | conditional `Update` | assert `≤ after` **and** advance the fence |
| A **single-tag** clause that is *not* the partition tag (a secondary read) | `ConditionCheck` | assert `≤ after` only — never advance |
| A tag in a **multi-tag (composite)** clause | conditional `Update` | assert `≤ after` and advance (composite reads cross partitions, so OCC needs the bump) |
| An untagged field (e.g. `@noDcbTag customerId`) | — | no fence at all |

### First writes — the creation guard

When the decision-model read returned nothing, `after` is absent: there is no fence position to check against. A plain append would let two concurrent first-writers both create the same entity. Instead, a first write emits a **creation guard** — one conditional item per `(eventType, partition value)` at `id="create#<eventType>#<key>:<value>", position="CREATE"`, gated on `attribute_not_exists`. Two concurrent first-writers collide on the guard, so at most one commits; the loser conflicts and retries.

Keying the guard by event *type* means it never collides with a *different* type already in the partition — a slice that reads only a subset of a partition's event types (and so legitimately sees nothing) is not falsely blocked.

### Worked example — `PlaceOrder` transaction

For `PlaceOrder({orderId:"ord-1", customerId:"cust-9", productIds:["prod-1","prod-2"]})`, with the two products already synced (so `after` is present), the produced `OrderPlaced` is tagged `[orderId:ord-1, productId:prod-1, productId:prod-2]` and partitioned by `orderId`. The append carries:

| Transact item | Why |
|---|---|
| `Put` `OrderPlaced` at `id="orderId:ord-1"` | the new event |
| `Update` `fence#orderId:ord-1` (check + advance) | `orderId` is the partition tag |
| `ConditionCheck` `fence#productId:prod-1` (check only) | secondary read — assert the product wasn't re-synced under us |
| `ConditionCheck` `fence#productId:prod-2` (check only) | same |

`customerId` is untagged, so it contributes no fence. The two `ConditionCheck`s preserve the availability decision (a concurrent re-sync of a product would advance its fence and conflict this order) **without** advancing `fence#productId:*` — so a *different* order of the same product does not spuriously conflict.

### Worked example — `RecordProductDemand` transaction

`RecordDemand({productId:"prod-1", orderId:"ord-1"})` reads a composite clause, so both tags are part of the consistency boundary. The produced `ProductDemandRecorded` is partitioned by `productId`, and the append carries:

| Transact item | Why |
|---|---|
| `Put` `ProductDemandRecorded` at `id="productId:prod-1"` | the new event |
| `Update` `fence#productId:prod-1` (check + advance) | composite tag |
| `Update` `fence#orderId:ord-1` (check + advance) | composite tag |

Both tags check **and** advance, because a composite read can match events across partitions.

## Retry on conflict

`handleSingleCommand` wraps the read-decide-append cycle in a retry loop (3 attempts). A `Conflict` means a relevant fence moved between the read and the append: the slice re-reads the now-current decision model, re-decides, and re-appends. Because well-behaved commands are idempotent (a command that would change nothing returns `Ok([])`), a retry that discovers the work is already done simply commits nothing.

## Source of truth

| Concern | Module |
|---|---|
| Query construction | `reventless-spec` · `DcbTag.buildQueryFromCommand`, `extractTags`, `extractTagsExpanded` |
| Read / decide / append / retry | `reventless-core` · `StateChangeSlice_Callback.handleSingleCommand` |
| Fence transaction, partition derivation, creation guard | `reventless-aws` · `DcbEventLogStorage_DynamoDb_Runtime.buildConditionalTransactItems` |

See also [DCB (Dynamic Consistency Boundary)](../architecture/dcb.md) for how slices, the command topic and the event log are wired together at deploy time.
