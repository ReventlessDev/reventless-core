# Consistency Boundaries

## Aggregates as Transaction Boundaries

An aggregate is the unit of consistency in event sourcing:

- All commands targeting an aggregate ID are serialized (processed one at a time)
- The aggregate's `decide` function sees the complete, up-to-date state
- Multiple events from a single command are atomically appended
- No cross-aggregate transactions — each aggregate is independent

This means: within one aggregate, consistency is guaranteed. Across aggregates, consistency is eventual.

## Aggregate Event Streams

Each aggregate instance has its own private event stream:

```
Product "p1": [ProductAdded, PriceChanged, PriceChanged]
Product "p2": [ProductAdded, NameChanged]
Order "o1":   [OrderPlaced, OrderShipped]
```

State reconstruction replays only the events for that specific ID. This is fast and isolated.

## Dynamic Consistency Boundaries (DCB)

DCB is an alternative to per-entity aggregates. Instead of one event stream per entity, all entities in a bounded context share a single event log:

```
Catalog Event Log: [
  ProductAdded({productId: "p1", ...}),
  CategoryAdded({categoryId: "c1", ...}),
  ProductAdded({productId: "p2", ...}),
  ProductPriceChanged({productId: "p1", ...}),
]
```

### Tag-Based Filtering

Commands specify which entity IDs they need. The runtime queries the shared log using tags:

```
Command: PlaceOrder({orderId: "o1", productIds: ["p1", "p2"]})
Tags: orderId="o1", productId IN ["p1", "p2"]

→ Query returns only events matching these tags
→ Decision model is built from the filtered subset
```

This enables **cross-entity decisions** — a single command can check state across multiple entity types atomically.

### Optimistic Concurrency

Because DCB uses a shared log, concurrent commands may conflict:

1. Command A reads events at position 100
2. Command B reads events at position 100
3. Command A appends events (succeeds, log is now at 102)
4. Command B tries to append — **conflict** (position changed)
5. Command B retries: re-reads events, re-decides, re-appends

Retries are automatic (up to 3 by default). The retry re-reads the log, so the decision reflects the latest state.

## When to Use Which

| Criteria | Aggregate | DCB |
|----------|-----------|-----|
| Entity has self-contained lifecycle | Yes | -- |
| Command needs state from multiple entities | -- | Yes |
| High write volume per entity | Yes | -- |
| Variable consistency boundary per command | -- | Yes |
| Entity exists to sync external data | -- | Yes |
| Need automation/translation slices | -- | Yes |
| Clear entity boundaries, simple domain | Yes | Either |

For detailed decision guidance with examples, read `docs/guides/aggregate-vs-dcb-decision-guide.md`.

## Mixing Approaches (Hybrid)

A single plugin can use both aggregates and DCB:

- Independent entities use aggregates (simpler, isolated)
- Interdependent entities share a DCB event log (cross-entity decisions)
- Both participate in the same plugin, share the same API
- Extension points work with both approaches

Rules:
1. Each entity is either an aggregate or DCB — never both
2. Interdependent entities must be in the same DCB event log
3. One DCB event log per plugin
4. Start with aggregates; introduce DCB when cross-entity consistency is needed
