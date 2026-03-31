# CQRS Patterns

## Command Query Responsibility Segregation

CQRS separates the write side (commands) from the read side (queries) into different models:

- **Write side:** Handles commands, enforces business rules, produces events
- **Read side:** Consumes events, builds query-optimized views, serves queries

Why separate? Because write-side and read-side have fundamentally different needs:
- Write side needs **consistency** (enforce invariants, prevent conflicts)
- Read side needs **performance** (fast queries, flexible access patterns, denormalized data)

## Commands

Commands express intent — a request for the system to do something:

- **Imperative naming:** `AddProduct`, `PlaceOrder`, `ChangePrice`
- **Can be rejected:** Business rules may prevent the command from succeeding
- **Carry data:** Include all information needed to make a decision
- **Targeted:** Directed at a specific entity (by ID)

```
Command: AddProduct({id: "p1", name: "Laptop", price: 999.99})
→ Accepted: produces ProductAdded event
→ Rejected: ProductAlreadyExists error
```

## Queries

Queries read data without modifying state:

- **Never change state:** Read-only access to pre-built views
- **Optimized for access patterns:** Each view is shaped for specific query needs
- **Eventually consistent:** May lag behind the write side by milliseconds

## Projections

Projections transform events into read model state. They are the bridge between the write side and read side:

```
Event: ProductAdded({id: "p1", name: "Laptop", price: 999.99})
→ Projection: Set("p1", {name: "Laptop", price: 999.99})

Event: PriceChanged({id: "p1", price: 899.99})
→ Projection: Update("p1", state => {...state, price: 899.99})
```

### Projection Operations

| Operation | Purpose |
|-----------|---------|
| `Set(id, state)` | Create or replace entire record |
| `Create(id, state)` | Create new record (fail if exists) |
| `Update(id, fn)` | Partially update existing record |
| `Delete(id)` | Remove a record |
| `Ignore` | Skip this event (not relevant to this view) |

### Multi-Source Projections

A read model can consume events from multiple sources (aggregates or event logs). Each source has its own mapping module that transforms source events into projection operations.

## Eventual Consistency

The read side is **eventually consistent** with the write side:

1. Command is accepted, events are appended to the event log
2. Events are published to the event topic
3. Projections consume events and update read models
4. Queries return the updated data

Steps 2-4 happen asynchronously. There is a brief window where the read side reflects the old state. This is usually milliseconds in practice.

**Why this is OK:**
- Users already experience eventual consistency (browser refresh, network latency)
- The write side is immediately consistent (commands are validated against current state)
- Read models can be rebuilt from scratch at any time by replaying all events

## Read Model Design

Each read model is optimized for a specific query pattern:

```
// ProductsView — list/detail queries
type state = {productId: string, name: string, price: float}

// OrderSummaryView — dashboard aggregation
type state = {customerId: string, totalOrders: int, totalSpent: float}
```

Different read models can project the same events into different shapes. This is a key benefit of CQRS — you don't compromise between write-side integrity and read-side performance.
