# Aggregate vs DCB: Decision Guide

This guide helps developers (and AI skills) choose between the **Aggregate** approach, the **DCB** (Dynamic Consistency Boundary) approach, or a **Hybrid** mix within a Reventless plugin.

---

:::tip Seeing it decided on a real domain
[Choosing an approach](/tutorials/choosing-an-approach) applies this guide to the
online shop, entity by entity — including the case that catches people out,
where a self-contained entity has to be DCB because another slice reads it.
:::

## Quick Decision Table

| Question | Aggregate | DCB Slices |
|----------|-----------|------------|
| Does the entity have a self-contained lifecycle? | Yes | -- |
| Do multiple entities share consistency rules? | -- | Yes |
| Is the command validation logic isolated to one entity? | Yes | -- |
| Must a command check state across multiple entity IDs? | -- | Yes |
| Is the entity independent of other entities in the same plugin? | Yes | -- |
| Does the entity exist mainly to sync external data? | -- | Yes |
| Do you need automation, inbound/outbound translation slices? | -- | Yes |
| Is the domain well-understood with clear entity boundaries? | Yes | Either |

**"--" means the approach is not a natural fit but is not prohibited.**

---

## The Two Approaches

### Aggregate Approach

An **Aggregate** is a write-side component with its own private event stream per entity instance. Each aggregate ID has its own event history, and state is reconstructed by replaying that history on every command.

**Components:**
- **Aggregate** (Spec + Behavior) — handles commands, produces events
- **EventLog** — one append-only stream per aggregate ID
- **ReadModel** + **Projections** — query-side views consuming aggregate events

**Command flow:**
```
Command → CommandTopic (FIFO, ordered per ID)
  → replay(id) → evolve events into state
  → decide(state, command) → new events
  → append to EventLog → publish to EventTopic
  → ReadModel projects events into QueryDb
```

### DCB Approach

A **DCB** uses a single shared event log per plugin. Commands are handled by **StateChangeSlices** that query the log using tags, build a minimal decision model, and append new events with optimistic concurrency.

**Components:**
- **StateChangeSlice** — handles commands, queries shared event log, produces events
- **StateViewSlice** — projects events into queryable state (read-side)
- **DcbEventLog** — single shared event log with tag-based filtering
- **AutomationSlice** — event-driven autonomous workflows
- **InboundTranslationSlice** — converts external input to commands
- **OutboundTranslationSlice** — reacts to events by calling external systems

**Command flow:**
```
Command → CommandTopic (shared, one per plugin)
  → extract tags from command
  → query DcbEventLog by tags + event types
  → evolve matching events into decision model
  → decide(state, command) → new events
  → conditional append (retry on conflict)
  → publish to EventTopic
  → StateViewSlice projects events into QueryDb
```

### Hybrid Approach

A single plugin can **mix both approaches**. Independent entities use aggregates; interdependent entities share a DCB event log. Both participate in the same plugin assembly, share the same API, and can define extension points and extensions.

---

## Decision Criteria

### 1. Entity Independence

**Choose Aggregate when** the entity has a self-contained lifecycle. Its commands only need the entity's own history to make decisions. No other entity's state is required at decision time.

**Choose DCB when** entities are interdependent. A command on entity A needs to check the state of entity B (or a set of entities) to decide whether to proceed.

**Examples:**
- **Aggregate:** `Category` — adding, renaming, or archiving a category only depends on the category's own state (does it exist? is it already archived?).
- **DCB:** `PlaceOrder` — placing an order must verify that all referenced products exist and are available, which requires reading `CatalogProduct` events alongside `Order` events.

### 2. Consistency Boundary Shape

**Choose Aggregate when** consistency boundaries align with entity identity. Every invariant you need to enforce involves exactly one entity ID.

**Choose DCB when** consistency boundaries span multiple entities or are determined at runtime. The set of events needed for a decision varies per command.

**Examples:**
- **Aggregate:** "A product cannot be added twice" — one product ID, one check.
- **DCB:** "An order can only be placed if all its line items reference existing products" — one order ID + N product IDs, checked atomically via tag-based query.

### 3. Command Granularity

**Choose Aggregate when** commands map naturally to a single entity with multiple operations. The aggregate accumulates rich state and each command variant operates on that state.

**Choose DCB when** commands are thin and focused. Each command does one thing, often involving a cross-entity check. DCB slices are naturally fine-grained — one slice per command type.

**Examples:**
- **Aggregate:** `Product` with commands `Add`, `UpdateName`, `UpdateDescription`, `UpdatePrice` — all operating on the same entity state. A single behavior module handles all variants.
- **DCB:** `AddProduct`, `ChangeProductName`, `ChangeProductDescription`, `ChangeProductPrice` — each is a separate StateChangeSlice. They share the event log but have independent decision logic.

### 4. External Data Synchronization

**Choose DCB when** an entity exists primarily to mirror data from another plugin or external system. DCB's StateChangeSlice + Extension pattern is purpose-built for this.

**Examples:**
- **DCB:** `SyncCatalogProduct` — a StateChangeSlice in the Ordering plugin that receives product data from the Catalog plugin's extension point and writes it to the shared event log. The Ordering plugin's `PlaceOrder` slice can then query these synced product events alongside order events.
- **Aggregate:** `ProductDemand` in the aggregate approach requires a dedicated aggregate with no user commands (extension-driven only), separate EventLog, separate ReadModel — more infrastructure for the same result.

### 5. Automation and Side Effects

**Choose DCB when** you need autonomous workflows or external system integration within the same bounded context.

DCB provides dedicated slice types:
- **AutomationSlice** — reacts to events by generating new commands (e.g., auto-ship orders after payment confirmation)
- **OutboundTranslationSlice** — reacts to events by calling external systems (e.g., send order confirmation email)
- **InboundTranslationSlice** — receives external input and translates to commands (e.g., import products from supplier feed)

The aggregate approach handles these scenarios through **Tasks** (for long-running operations) and **EventMappers** (for aggregate-to-aggregate event routing), but the DCB slice types are more explicit and composable.

### 6. Event Log Size and Query Performance

**Choose Aggregate when** you expect high event volumes per entity. Each aggregate has its own stream — replay cost scales with the entity's history, not the entire domain.

**Choose DCB when** individual entities have modest event counts but you need flexible cross-entity queries. All events share one log, filtered by tags.

**Trade-offs:**
- **Aggregate replay** is fast for small streams (< 1000 events per ID) but grows linearly. Snapshots can mitigate this.
- **DCB queries** use DynamoDB secondary indexes indexed by tag values. Cross-entity queries are efficient but all events compete for the same table throughput.

---

## Advantages and Consequences

### Aggregate Approach

| Advantage | Consequence |
|-----------|-------------|
| Clear entity boundaries — one aggregate, one event stream, one behavior | More infrastructure per entity (CommandTopic, EventLog, EventTopic per aggregate) |
| Strong consistency within entity — commands serialized by ID | No cross-entity transactions — must use sagas or extension-driven aggregates for coordination |
| Full audit trail per entity — replay any ID to any point in time | State reconstruction cost — every command replays the full event history |
| Isolated testing — BehaviorTest DSL tests decide/evolve in pure functions | Separate ReadModel infrastructure required for every query view |
| Mature pattern — well-documented, widely understood | Idempotency must be explicit (`Ok([])` for no-change commands) |
| Efficient per-ID storage — DynamoDB partition per aggregate ID | Event schema is per-aggregate — no shared type across entities |

### DCB Approach

| Advantage | Consequence |
|-----------|-------------|
| Shared event log — one DcbEventLog per plugin, simpler infrastructure | All events share one table — throughput planning is domain-wide |
| Dynamic consistency — tag-based queries determine boundaries at runtime | Tag annotations required on all filterable fields (`@s.matches(DcbTag.string)`) |
| Cross-entity decisions — one query can span multiple entity types | Optimistic concurrency with retries (up to 3) — conflicts are expected |
| Fine-grained slices — one slice per command, easy to add/remove | More files per domain concept (one slice file per command vs one behavior with all commands) |
| Built-in automation and translation slices | DCB-specific slice types only work with DcbEventLog, not aggregates |
| Minimal decision model — evolve only the fields needed for the decision | Event type union grows as slices are added (all events in one schema) |
| No separate ReadModel wiring — StateViewSlice projects directly | StateViewSlice is simpler but less flexible than ReadModel (single event source) |

### Hybrid Approach

| Advantage | Consequence |
|-----------|-------------|
| Best of both — independent entities get aggregates, interdependent entities share DCB | Two mental models in one plugin — team must understand both |
| Natural domain decomposition — each entity uses its natural boundary style | Plugin assembly is larger (both aggregate and DCB parameters) |
| Incremental migration — start with aggregates, introduce DCB where needed | Must choose per entity — no entity can be both |

---

## Use Cases

### Use Case 1: Product Catalog (Aggregate)

A catalog where products have independent lifecycles. Adding a product only checks if that product ID already exists. Updating a product only needs the product's current state.

**Why Aggregate:** Each product is fully self-contained. No product command needs another product's state. Clear entity boundary = clear aggregate.

```
Aggregate: Product (Add, UpdateName, UpdatePrice, Archive)
ReadModel: ProductsView (projects product events)
```

### Use Case 2: Order Placement with Inventory Check (DCB)

An ordering system where placing an order must verify that all referenced products exist and are available. The decision spans order state + product catalog state.

**Why DCB:** The `PlaceOrder` command needs to read product availability events alongside order events. A tag-based query on `productId` pulls events from both `SyncCatalogProduct` and `PlaceOrder` slices atomically.

```
StateChangeSlice: PlaceOrder (queries product + order events)
StateChangeSlice: SyncCatalogProduct (mirrors catalog data)
StateViewSlice: OrdersView, AvailableProductsView
AutomationSlice: AutoShipOrder (auto-ships after payment)
OutboundTranslationSlice: SendOrderConfirmation (emails)
```

### Use Case 3: Category Management (Aggregate in Hybrid)

Categories in a catalog have a simple, independent lifecycle alongside a DCB-based product system.

**Why Aggregate in a Hybrid plugin:** Category has no dependency on products or other entities. It doesn't need cross-entity consistency. Making it an aggregate keeps it simple while the more complex product/demand domain uses DCB.

```
Plugin: Catalog
  Aggregate: Category (Add, Rename, Archive)
  ReadModel: CategoriesView
  DCB: Product slices, ProductDemand slices (shared event log)
```

### Use Case 4: Customer Management (Aggregate)

Customers register, update profile fields, and deactivate. Each operation depends only on the customer's own state.

**Why Aggregate:** Classic self-contained entity. No cross-customer invariants. Registration checks if the customer exists; updates check current state; deactivation is idempotent.

```
Aggregate: Customer (Register, UpdateEmail, UpdateAddress, Deactivate)
ReadModel: CustomersView
```

### Use Case 5: Reservation System with Capacity Limits (DCB)

A venue booking system where reserving a seat must check remaining capacity across all existing reservations for the same event.

**Why DCB:** The "reserve seat" command must count existing reservations for the event (cross-entity query by `eventId` tag) and compare against venue capacity. The consistency boundary spans all reservations for one event.

```
StateChangeSlice: ReserveSeat (queries reservations by eventId tag)
StateChangeSlice: CancelReservation
StateViewSlice: EventAvailabilityView
StateViewSlice: ReservationsView
```

### Use Case 6: Supplier Product Import (DCB with InboundTranslation)

An external supplier feed provides product data that must be validated and imported into the catalog.

**Why DCB:** InboundTranslationSlice receives external JSON, validates it (currency, required fields), and translates to `AddProduct` commands. This is a DCB-native pattern with no aggregate equivalent.

```
InboundTranslationSlice: ImportProduct (validates + translates)
StateChangeSlice: AddProduct (handles the generated command)
```

### Use Case 7: Audit Log / Compliance Tracking (Aggregate)

A compliance system where every entity action must be independently auditable with full replay capability.

**Why Aggregate:** Per-entity event streams provide a complete audit trail. You can replay any entity to any point in time. The isolation guarantee means one entity's events never mix with another's.

---

## Decision Flowchart

```
Does the command need state from multiple entity types?
  ├─ Yes → DCB
  └─ No
      │
      Does the entity have a self-contained lifecycle?
        ├─ Yes → Aggregate
        └─ No (e.g., sync-only, reactive)
            │
            Is it part of a plugin that already uses DCB?
              ├─ Yes → DCB (add as another slice)
              └─ No → Consider DCB or extension-driven Aggregate
```

---

## Mixing Approaches: Guidelines

1. **Per-entity decision.** Each entity in a plugin is either an aggregate or a set of DCB slices. Never both.

2. **Group interdependent entities in DCB.** If entities A and B share consistency rules, both must be DCB slices on the same DcbEventLog.

3. **Keep independent entities as aggregates.** If an entity's commands never need another entity's state, an aggregate is simpler and more isolated.

4. **Extension points work with both.** Both aggregates and DCB slices can define extension points and extensions. The mapping layer abstracts the internal approach.

5. **One DcbEventLog per plugin.** All DCB slices in a plugin share a single event log. You cannot have multiple DcbEventLogs in one plugin.

6. **Start with aggregates, introduce DCB when needed.** If you're unsure, start with aggregates. When you hit a cross-entity consistency requirement, convert those entities to DCB slices. The hybrid approach makes this migration incremental.

---

## Naming: what a name means in each approach

The last table says a DCB plugin has one shared CommandTopic and one shared
EventTopic where the aggregate approach has one of each per aggregate. That is a
deployment fact with a modelling consequence people meet late, so it is worth
saying directly:

> **In a DCB plugin, a command name and an event name are routing keys, and the
> namespace is the whole plugin. In the aggregate approach they are scoped to the
> component that declares them.**

### What that changes

**Aggregates may repeat each other's names.** Commands are addressed per component
channel, and an aggregate's event stream is entity-scoped — consumers bind the
source module (`Mapping.Make(Product, …)`) rather than matching a bare name. So
`Category.Added` and `Product.Added` coexist in the shipped aggregates example and
nobody has to think about it.

**DCB slices may not.** The runtime builds one `handlersByType` map across every
StateChangeSlice in the plugin and dispatches on the incoming command's TAG alone.
A DCB query selects on the event type name the same way.

**The GraphQL surface shows the difference**, which is usually where it is first
noticed:

```graphql
Ordering_Customer_Register(...)   # aggregate: plugin, component, command
Ordering_Subscribe(...)           # DCB slice: plugin, command
```

### Commands and events are not the same case

They are both routing keys, but for opposite reasons, and it matters if you ever
consider qualifying them:

- A **command** has exactly one handler by definition. Its flat namespace is an
  implementation choice, and a duplicate is simply a bug.
- An **event** has as many readers as care to consume it — `PlaceOrder` reads
  `CatalogProductSynced`, produced by a different slice entirely. **A flat event
  namespace is what a dynamic consistency boundary *is*.** Qualifying event names
  by component would couple every reader to its producer, which is the thing DCB
  exists not to do.

So the two constraints feel alike and are not: one is a detail, the other is the
model.

### What a duplicate command name does

Nothing, at first. The second registration overwrites the first and the plugin
deploys; the losing slice is simply never reached, and the runtime notices only
later, when it goes to stamp owner fields on a command it cannot attribute.

The plugin structure therefore **refuses it at build time**, naming the command
and both slices. Aggregates are exempt and are not checked.

### How to avoid it

Qualify names you might repeat, with whatever the slice is about:

```
AttachProductImage   ProductImageAttached   ProductImages
AttachCategoryImage  CategoryImageAttached  CategoryImages
```

That is not a style rule invented for this page — it is what the
[domain traits](./domain-traits.md) emitters do, and it is why one trait can be
grafted onto two entities of the same plugin. It is also the reason a trait cannot
hand a DCB slice its own constructors the way it can hand them to an aggregate: a
spread cannot rename what it splices, so the trait's fixed names would land in the
plugin-wide namespace and collide with the next host.

---

## Reference: Component Mapping

| Aggregate Approach | DCB Approach | Purpose |
|-------------------|-------------|---------|
| Aggregate (Spec + Behavior) | StateChangeSlice | Command handling, event production |
| EventLog (per ID) | DcbEventLog (shared, tag-filtered) | Event storage |
| ReadModel + Projections | StateViewSlice | Query-side projections |
| EventMapper | AutomationSlice | Event-driven command generation |
| Task | InboundTranslationSlice | External data ingestion |
| Side Effect Handler | OutboundTranslationSlice | External system integration |
| CommandTopic (per aggregate) | CommandTopic (shared per plugin) | Command delivery |
| EventTopic (per aggregate) | EventTopic (shared) | Event distribution |

---
