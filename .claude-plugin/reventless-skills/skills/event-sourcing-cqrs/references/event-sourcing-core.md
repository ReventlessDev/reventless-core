# Event Sourcing Core Concepts

## Events as Facts

An event is an immutable record of something that happened in the past:

- **Past tense:** `ProductAdded`, `OrderPlaced`, `PriceChanged` — never `AddProduct`
- **Immutable:** Once recorded, an event can never be modified or deleted
- **Factual:** Events are always true — they represent what happened, not what was requested
- **Ordered:** Events within a stream have a defined sequence

## Append-Only Event Log

All state changes are stored as a sequence of events in an append-only log:

```
Event #1: ProductAdded({id: "p1", name: "Laptop", price: 999.99})
Event #2: PriceChanged({id: "p1", price: 899.99})
Event #3: ProductAdded({id: "p2", name: "Phone", price: 499.99})
```

There is no `UPDATE` or `DELETE`. The current state is derived by replaying events.

## State Reconstruction via Replay

Current state is computed by folding events from the beginning:

```
initialState = NotCreated
  + ProductAdded({name: "Laptop", price: 999.99})
  = Created({name: "Laptop", price: 999.99})
  + PriceChanged({price: 899.99})
  = Created({name: "Laptop", price: 899.99})
```

This is the `evolve` function: `(state, event) => newState`

## Command Processing

Commands are requests to change state. They go through a decision function:

```
1. Receive command: ChangePrice({id: "p1", price: 799.99})
2. Replay events for "p1" to get current state
3. Run decide(currentState, command):
   - If product exists → Ok([PriceChanged({price: 799.99})])
   - If product doesn't exist → Error(ProductNotFound)
4. If Ok: append new events to the log
5. If Error: reject the command
```

This is the `decide` function: `(state, command) => result<array<event>, error>`

## Idempotency

Commands that would produce no change should return `Ok([])` (empty event array), not an error:

```
decide(Created({name: "Laptop"}), Rename({name: "Laptop"}))
  = Ok([])  // name is already "Laptop", no-op
```

This is important because commands may be retried (network failures, at-least-once delivery).

## Event Schema Evolution

As the domain evolves, event types change. Strategies for handling this:

- **Upcasting:** Transform old event shapes to new shapes during replay
- **Versioning:** Include version information in event metadata
- **Additive changes:** Add new event types rather than modifying existing ones (preferred)
- **Backward compatibility:** New code must handle old events; old events are never rewritten

## Snapshots

When an entity has many events, replaying from the beginning becomes expensive. Snapshots optimize this:

- **Snapshot:** A cached state at a known event position
- **Replay from snapshot:** Start from snapshot state, replay only newer events
- **Invalidation:** Snapshots are optimization — always rebuildable from events
- **Trade-off:** Snapshot maintenance cost vs replay performance

Reventless does not currently provide built-in snapshot support. For most use cases, event streams are small enough that full replay is fast.

## Benefits of Event Sourcing

1. **Complete audit trail** — every change is recorded, queryable, replayable
2. **Temporal queries** — reconstruct state at any point in time
3. **Event-driven architecture** — events naturally feed other systems
4. **Debugging** — replay the exact sequence of events that led to a bug
5. **No data loss** — storing facts means no information is discarded
