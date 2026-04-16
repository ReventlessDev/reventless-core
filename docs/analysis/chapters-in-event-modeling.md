# Chapters in Event Modeling: Analysis for Reventless

## Two Distinct Uses of "Chapter"

The term "chapter" in the context of Event Modeling covers two related but distinct ideas that are worth separating clearly:

1. **Structural chapters** — a way to organize and segment a large event model into comprehensible, independently-navigable sections. This is a modeling and code organization concern. It does not require any additional infrastructure and is already well-supported in Reventless.

2. **Temporal chapters ("Closing the Books")** — a pattern borrowed from accounting where an event stream is divided into bounded time periods. Each period closes with a summary event and opens fresh, keeping active working sets small. This is a performance, retention, and lifecycle concern. It requires explicit modeling and additional infrastructure.

These two uses are often conflated. The key insight is: **you can adopt structural chapters without ever implementing temporal chapters.** Structural organization is always beneficial; temporal chapters are an optional optimization for long-lived entities with high event volumes.

---

## Part 1: Structural Chapters — Organizing Large Event Models

### What It Is

As a Reventless application grows, the event model diagram — and the corresponding code — can become difficult to navigate. Structural chapters are simply a way to segment the model into named, cohesive groups. In a diagram, this looks like horizontal bands (swimlanes) or labelled sections. In code, it maps directly to folder organization within a plugin.

This is purely an organizational tool. There is no runtime behavior associated with structural chapters. They improve developer comprehension, team ownership, and navigability without adding infrastructure complexity.

### How Reventless Supports This Natively

Reventless already treats folder structure as the primary organizational unit. The `generate-plugin` tool and `reventless-ppx` both read folder names to classify components — this means that how you structure your source folders directly shapes the generated plugin composition and the boilerplate the PPX injects.

#### Folder-Based Slice Organization

The online-shop-dcb example demonstrates the pattern:

```
catalog/src/
├── Category/                       ← structural chapter: Category domain
│   ├── StateChangeSlice/
│   │   ├── AddCategory.res
│   │   ├── ArchiveCategory.res
│   │   └── RenameCategory.res
│   └── StateViewSlice/
│       └── CategoriesView.res
├── Product/                        ← structural chapter: Product domain
│   ├── StateChangeSlice/
│   │   ├── AddProduct.res
│   │   ├── ChangeProductPrice.res
│   │   └── RecordProductDemand.res
│   ├── StateViewSlice/
│   │   ├── ProductsView.res
│   │   └── ProductDemandView.res
│   └── InboundTranslationSlice/
│       └── ImportProduct.res
├── Extension/
│   └── OrdersExtension.res
└── ExtensionPoint/
    └── ProductsExtensionPointMapping.res
```

The `generate-plugin` tool recognizes slice folder names (`StateChangeSlice/`, `StateViewSlice/`, `AutomationSlice/`, `InboundTranslationSlice/`, `OutboundTranslationSlice/`, `Aggregate/`, `ReadModel/`, `ExtensionPoint/`, `Extension/`, `Task/`) regardless of the parent folder — so grouping slices under `Category/` or `Product/` is purely for developer organization and has no effect on how the plugin is wired.

#### PPX Boilerplate Reduction

The `@@reventless.spec` PPX attribute, when applied to a `.res` file in a recognized slice folder, automatically injects:

- `let name` — derived from the filename (e.g., `AddProduct.res` → `"AddProduct"`)
- `module Id` — standard ID module
- `let moduleUrl` — source location binding
- For `StateViewSlice/` files: `open Reventless.Projection` (brings `Set`, `Update`, `UpdateWithDefault`, `Delete` into scope) and `let config = config(); let subIdConfig = None`
- For `*ExtensionPointMapping*` files: `open ReventlessInfra.ExtensionPointMapping` (brings `PublishEvent`, `PublishCommand`, `Call` into scope)
- For files with `*Id: string` fields: `@s.matches(DcbTag.string)` — DCB tag annotations, applied automatically for all files inside `*Slice/` folders

The `@@reventless.behavior` attribute on behavior files automatically:
- Opens and aliases the corresponding spec module (derived from filename by stripping `Behavior` suffix)
- Injects `let moduleUrl`

This means the folder structure is not just organizational documentation — it directly determines which PPX injections apply and what the plugin generator produces.

#### The Swimlane Model

Structural chapters also appear as horizontal swimlanes in event modeling diagrams. Reventless already formalizes these swimlanes as distinct slice types in `Plugin.DcbSpec`:

```
StateChangeSlices  ← command handling, write side
StateViewSlices    ← projections, read side
AutomationSlices   ← event-to-command (internal policies)
InboundTranslationSlices   ← external → internal
OutboundTranslationSlices  ← internal → external
```

This is a structural chapter pattern that is already implemented. It cleanly separates concerns and provides natural team boundaries.

### When Structural Chapters Are Sufficient

For most applications, structural chapters alone provide all the organizational benefit needed:

- The plugin generates correctly regardless of subdirectory grouping
- Developers can navigate by domain area (`Category/`, `Product/`) or by slice type (all `StateChangeSlice/` files)
- The event model diagram can be annotated with chapter boundaries as a documentation aid
- No runtime cost, no additional infrastructure

**Structural chapters should always be used.** They cost nothing and make the codebase significantly easier to navigate as it grows.

---

## Part 2: Temporal Chapters ("Closing the Books") — Optional

### What It Is

A **temporal chapter** is a bounded lifecycle segment of an event stream. The concept is borrowed from double-entry bookkeeping: at the end of each accounting period, all transactions are summarized into a closing balance. That summary becomes the opening balance of the next period. The prior period's transaction detail is no longer needed for day-to-day operations.

Applied to event sourcing, a temporal chapter represents a **bounded time segment** of an entity's event stream, with a defined beginning and end:

- **Opens** with a summary event carrying forward the essential state from prior chapters
- **Contains** the events that occurred during that period
- **Closes** with a closing event summarizing the chapter's final state

The closed chapter becomes immutable and archivable. The new chapter starts fresh, keeping the active working set small.

### The Metaphor

Think of an entity's event history as a book. Without temporal chapters, it is a single unbroken wall of text. With chapters, the narrative is segmented into meaningful periods.

### Concrete Examples

| Domain | Chapter Boundary | Open Event | Close Event |
|--------|-----------------|------------|-------------|
| Cash Register | Cashier shift | `ShiftOpened(openingBalance)` | `ShiftClosed(closingBalance)` |
| Accounting | Monthly period | `MonthOpened(openingBalances)` | `MonthClosed(closingBalances)` |
| Hotel | Business day | `DayOpened(roomStates)` | `DayClosed(occupancyReport)` |
| Subscription | Billing cycle | `CycleStarted(plan, balance)` | `CycleCompleted(invoice)` |
| Inventory | Stock-take period | `PeriodOpened(currentStock)` | `PeriodClosed(reconciledStock)` |

### This Pattern Is Optional

Temporal chapters add significant modeling complexity. They are justified only when:

- An entity is **long-lived** with a high and ongoing rate of events (thousands or more)
- There are **natural business boundaries** that align with chapter transitions (shifts, billing cycles, fiscal periods)
- Replay performance or event log storage has become an actual, measured bottleneck

For most entities — orders, tasks, short-lived workflows — temporal chapters are not needed. The event stream terminates naturally (an order is fulfilled, a task is completed) before volume becomes a concern.

**The structural chapter pattern from Part 1 is always useful. Temporal chapters are an optimization applied selectively.**

### What Temporal Chapters Are Used For

#### 1. Performance — Keeping Streams Short

The primary motivation. When state is reconstructed by replaying events, a stream with thousands of events becomes a performance bottleneck. Temporal chapters ensure the active segment contains only events from the current period — typically tens to hundreds of events rather than thousands.

#### 2. Data Retention and Archival

Closed chapters can be moved to cold storage (S3, archive tables) while the active chapter remains in the hot path. This is a natural fit for compliance requirements (GDPR right to erasure of old periods, regulatory retention windows).

#### 3. Natural Business Boundaries as First-Class Concepts

Many business processes have inherent temporal boundaries that chapters make explicit: fiscal periods, shifts, billing cycles, seasons. Making these boundaries first-class in the event model aligns the technical model with how the business thinks.

#### 4. Schema Evolution

When a chapter closes, the summary event can be written using the latest schema version, eliminating the need to support reading old event formats within the active chapter.

#### 5. Conflict Reduction

Shorter event histories mean fewer events to check for optimistic concurrency conflicts, reducing the likelihood of retries in high-contention scenarios.

### Advantages

1. **Bounded replay cost**: State reconstruction reads only the current chapter, with predictable and bounded event counts.
2. **Natural archival**: Closed chapters are immutable artifacts that can be compressed, moved to cold storage, or deleted after a retention period.
3. **Domain alignment**: The model reflects real business concepts (shifts, periods, cycles).
4. **Simpler snapshots**: The chapter's opening summary event IS the snapshot — no separate snapshot infrastructure needed.
5. **Cleaner schema evolution**: Each new chapter can adopt the latest schema version in its opening event.

### Consequences and Trade-offs

1. **Added modeling complexity**: Every entity needs explicit lifecycle analysis. The modeler must identify when chapters open and close, what state carries forward, and what gets left behind.
2. **Cross-chapter queries become harder**: Questions spanning all time require reading multiple chapters or a separate all-time projection.
3. **Carry-forward logic is critical**: The summary/opening event must capture ALL state needed for the next chapter. Missing a field means that information is lost from the active working set.
4. **Chapter transition is a complex operation**: Closing one chapter and opening the next must be atomic or carefully orchestrated.
5. **Not universally applicable**: Some entities don't have natural temporal boundaries (e.g., a user profile). Forcing artificial chapters on these adds complexity without clear benefit.
6. **Read model rebuild**: Rebuilding projections from scratch requires reading all chapters in sequence.

---

## Temporal Chapters in the Two Approaches: Aggregates vs. DCB

Reventless supports two fundamentally different event sourcing paradigms. Temporal chapters apply to both, but the mechanics, trade-offs, and implementation strategies differ significantly.

### Recap: How the Two Approaches Differ

| Aspect | Aggregate-Based | DCB-Based |
|--------|----------------|-----------|
| **Event storage** | Per-aggregate-instance streams (partitioned by aggregate ID) | Single shared event log per bounded context |
| **Stream identity** | `(aggregateType, aggregateId)` → own stream | All events in one log, filtered by content tags |
| **State reconstruction** | Replay all events for one aggregate ID | Query tag-filtered events, build ephemeral decision model |
| **Concurrency** | Per-stream sequence number (implicit sharding) | Optimistic locking via conditional append on tag queries |
| **Consistency boundary** | Static — fixed to the aggregate | Dynamic — defined by each command's query |

### Temporal Chapters for Aggregate-Based Event Sourcing

In the aggregate world, temporal chapters are a **natural fit** because streams are already per-entity. The pattern maps directly:

#### Stream Identity Strategies

1. **Rolling current stream**: A single stream ID (e.g., `CashRegister-42`) that gets truncated/archived when a chapter closes. Simple but requires stream truncation support in the EventLog adapter.

2. **Dedicated chapter streams**: Each chapter gets its own stream (e.g., `CashRegister-42_shift-7`, `CashRegister-42_shift-8`). More explicit, naturally immutable once closed, but requires the aggregate to know which chapter stream to use.

#### How It Works

```
Stream: Category-cat-1
  Chapter 1 (creation → first archive):
    pos 1: CategoryAdded { name: "Electronics" }
    pos 2: CategoryRenamed { name: "Consumer Electronics" }
    pos 3: CategoryChapterClosed { summary: { name: "Consumer Electronics", active: true } }

  Chapter 2 (after first archive):
    pos 4: CategoryChapterOpened { carryForward: { name: "Consumer Electronics", active: true } }
    pos 5: CategoryArchived {}
    (stream ends — entity lifecycle complete)
```

The aggregate's `Behavior` module gains chapter awareness:
- `initFromSummary: summary => state` — initialize from a chapter's carry-forward
- `toSummary: state => summary` — compute summary for chapter closing
- The `replay` operation starts from the latest `ChapterOpened` event

#### Reventless Impact

- **EventLog adapter**: Must support replay-from-position (or replay-from-latest-chapter)
- **Aggregate_Operations**: Modified to check for chapter opening events during replay
- **Aggregate Spec / Behavior**: Extended with optional `summary` type and `initFromSummary`/`toSummary` functions
- **Relatively contained**: Changes are scoped to the aggregate component — no impact on read models, plugins, or cross-aggregate concerns

#### When It Makes Sense

- Long-lived aggregates with many events (e.g., accounts, ledgers, inventory items)
- Entities with natural lifecycle periods (shifts, billing cycles, fiscal periods)
- Performance optimization for aggregates where replay becomes a bottleneck
- **Not needed** for short-lived aggregates (e.g., orders that go through a finite workflow and then freeze)

### Temporal Chapters for DCB-Based Event Sourcing

In the DCB world, there are no per-entity streams to segment. The single shared event log and dynamic consistency boundaries create a fundamentally different challenge.

#### The Core Tension

DCB's power comes from **dynamic queries** — each StateChangeSlice reads exactly the events it needs via tag-based filtering. The consistency boundary is defined by the query, not by a stream. Temporal chapters must work within this model without destroying its flexibility.

#### Option A: Global Log Chapters (Log-Level Segmentation)

The entire DcbEventLog is divided into temporal chapters:

```
Chapter 1: positions 0–10000 (2024-Q1)
Chapter 2: positions 10001–25000 (2024-Q2)
Chapter 3: positions 25001–current (2024-Q3)
```

Each chapter boundary includes **summary events** that carry forward the current state of all active entities. StateChangeSlices only query within the current chapter.

**Pros**: Simple conceptually. Bounded read windows. Clear archival boundaries.
**Cons**: Summary events must capture state for ALL entities — potentially very large. Chapter transitions affect the entire system. Doesn't align well with per-entity lifecycles.

#### Option B: Entity-Level Chapters via Tags (Entity-Level Segmentation)

Chapters are scoped to individual entities within the shared log. A `ChapterClosed` and `ChapterOpened` event pair for a specific entity (identified by tags) carries forward that entity's state:

```
pos 100: ProductAdded { productId: "prod-1", name: "Widget" }
pos 200: PriceChanged { productId: "prod-1", price: 29.99 }
pos 300: ProductChapterClosed { productId: "prod-1", summary: { name: "Widget", price: 29.99, stock: 42 } }
pos 301: ProductChapterOpened { productId: "prod-1", carryForward: { name: "Widget", price: 29.99, stock: 42 } }
pos 400: PriceChanged { productId: "prod-1", price: 24.99 }
```

A StateChangeSlice querying for `productId: "prod-1"` could use `after: 301` to skip all pre-chapter events, reading only from the latest chapter opening.

**Pros**: Per-entity granularity. Natural fit for entity lifecycle events. Doesn't require global coordination.
**Cons**: Old events remain in the log (just skipped). Archival requires a separate mechanism. The shared log grows regardless. Chapter events pollute the event union with infrastructure concerns.

#### Option C: Hybrid — Compacted Chapters with Log Rotation

Combine entity-level chapter events with periodic log rotation:

1. Entity-level `ChapterOpened`/`ChapterClosed` events provide per-entity carry-forward state
2. Periodically, a new physical log partition is started (similar to Kafka log compaction/rotation)
3. Only entities with activity in the new partition get `ChapterOpened` events — dormant entities are excluded until they receive new commands
4. The old partition becomes read-only and archivable

#### DCB-Specific Complication: Cross-Entity Decision Models

A key DCB strength is that a StateChangeSlice can read events from **multiple entities** in a single query. With temporal chapters, each entity may be at a different chapter boundary. The StateChangeSlice must:
- Find the latest `ChapterOpened` for each entity involved in the query
- Use the earliest of those positions as its `after` cursor
- Or maintain a separate chapter index per entity and merge results

This is significantly more complex than the aggregate case where each entity has its own isolated stream.

### Comparison: Temporal Chapters in Both Approaches

| Aspect | Aggregates | DCB |
|--------|-----------|-----|
| **Stream to segment** | Per-entity stream (natural unit) | Shared log (no natural per-entity boundary) |
| **Chapter scope** | Single entity, single aggregate type | Must choose: global, per-entity, or hybrid |
| **Implementation complexity** | Low — contained within aggregate component | High — cross-cutting concern touching DcbEventLog, all slices |
| **Carry-forward state** | Aggregate state (well-defined, single type) | Decision model per slice (multiple slices may need different summaries for the same entity) |
| **Cross-entity impact** | None — chapters are per-aggregate | Significant — cross-entity queries must reconcile chapter boundaries |
| **Concurrency during transition** | Low risk — per-entity stream isolation | High risk — chapter closing for one entity may conflict with commands from other slices |
| **When it makes sense** | Long-lived aggregates with many events | Large shared logs with entities that accumulate many events |

---

## Alternative Approaches to Structuring Events

Temporal chapters are one way to manage growing event histories, but they are not the only approach. Especially in DCB-based systems, the question of **how to structure and organize events** has multiple dimensions.

### The DCB Structuring Problem

In a DCB-based Reventless application, the event log grows along two axes:

1. **Depth**: More events per entity over time (the temporal chapter problem)
2. **Breadth**: More entity types and slices sharing the same log (the structural organization problem)

The online-shop-dcb example already shows this: the Catalog plugin has one `CatalogEventLog` containing events for Products, Categories, AND ProductDemand — with multiple StateChangeSlices, StateViewSlices, and translation slices all operating on the same log. As the domain grows, this single event union becomes a wide, complex type.

The following approaches address different aspects. They are not mutually exclusive — many can be combined.

### Approach 1: Multiple DcbEventLogs per Plugin (Domain Partitioning)

Instead of one event log per plugin, split into **multiple event logs per domain area** within the plugin:

```
CatalogPlugin/
  ProductEventLog     → ProductAdded, PriceChanged, NameChanged, ...
  CategoryEventLog    → CategoryAdded, CategoryRenamed, CategoryArchived
  DemandEventLog      → DemandRecorded, DemandRevoked
```

Each log has a smaller event union and fewer slices. Tag-based filtering becomes simpler because the events are already pre-partitioned by concern.

**Pros**:
- Smaller event unions — easier to understand and maintain
- Natural DynamoDB partitioning — separate tables, separate capacity
- Independent scaling per domain area
- Reduced secondary index breadth

**Cons**:
- **Loses cross-entity consistency** — the core DCB advantage. If `AddProduct` needs to check category existence, and category events are in a different log, the conditional append can't span both logs.
- More infrastructure to manage

**When to use**: When entities within a plugin are truly independent and rarely need cross-entity consistency guarantees.

**Reventless impact**: Already supported — a plugin can have multiple `DcbEventLog` instances.

### Approach 2: Hierarchical Tag Namespaces

Instead of splitting logs, use **hierarchical tag conventions** to organize events within a single log:

```
Tags:
  domain:product / entity:prod-1
  domain:category / entity:cat-1
  domain:demand / entity:prod-1
```

**Pros**: Single log — full DCB consistency preserved. Organizational clarity without infrastructure changes.
**Cons**: Doesn't solve the growing event union problem. Doesn't help with event accumulation over time.

**Reventless impact**: Purely a convention — no framework changes needed.

### Approach 3: Event Categorization by Slice Type (Swimlanes)

Already implemented in Reventless via the `Plugin.DcbSpec` structure (separate arrays for stateChangeSlices, stateViewSlices, automationSlices, translationSlices). This is the structural chapter pattern from Part 1.

### Approach 4: Event Type Subsetting (Slice-Scoped Event Types)

Instead of every slice knowing about every event in the log, define **event type subsets** per slice:

```rescript
// The full event log union
type event =
  | ProductAdded(...)
  | PriceChanged(...)
  | CategoryAdded(...)
  | CategoryArchived(...)

// AddProduct slice only cares about:
type relevantEvent = ProductAdded(...) | CategoryAdded(...)
```

**Pros**: Type-safe. Query optimization. Explicit dependencies between slices and events.
**Cons**: ReScript's type system makes variant subsetting verbose.

**Reventless impact**: Partially supported — `DcbTag.query` accepts `eventTypes` for filtering. Could be formalized in `StateChangeSlice.Spec` as a required declaration.

### Approach 5: Snapshots as a Technical Optimization

Rather than the domain-driven temporal chapter approach, use **infrastructure-level snapshots** transparent to domain logic:

```
EventLog stores events normally.
A background process periodically:
  1. Reads all events for an entity (by tag query)
  2. Folds them through the slice's reduce function
  3. Stores the resulting state as a snapshot record
  4. Records the position up to which events were folded

On next read, the slice:
  1. Loads the latest snapshot
  2. Reads only events AFTER the snapshot position
  3. Folds those events on top of the snapshot state
```

**Pros**: Transparent to domain logic. Solves the depth problem without requiring lifecycle modeling. Works for entities without natural temporal boundaries.
**Cons**: Separate infrastructure. Schema changes require snapshot invalidation. Not a domain concept.

**When to use**: As a last resort for performance optimization, after domain modeling (temporal chapters) and query optimization have been exhausted.

### Approach 6: Event Log per Bounded Context with Cross-Context Extensions

This is the approach Reventless already takes at the **plugin level**: each plugin has its own DcbEventLog (or set of aggregates), and cross-plugin communication happens via extension points. The question is whether this pattern should be applied **within** a plugin as well.

**Reventless impact**: Already supported — a plugin can contain multiple DcbEventLogs and extension points.

### Comparison Matrix

| Approach | Addresses Depth | Addresses Breadth | Preserves DCB Consistency | Domain-Driven | Implementation Effort |
|----------|:-:|:-:|:-:|:-:|:-:|
| **Structural Chapters (folder org.)** | No | Yes (organizational) | Yes | Yes | Already done |
| **Temporal Chapters (closing the books)** | Yes | No | Depends on option | Yes | High |
| **Multiple Logs** | No | Yes | No (per-log only) | Somewhat | Medium |
| **Tag Namespaces** | No | Yes (logical) | Yes | No | Low |
| **Swimlanes** | No | Yes (organizational) | N/A | Yes | Already done |
| **Event Subsetting** | No | Yes (type safety) | Yes | Somewhat | Medium |
| **Snapshots** | Yes | No | Yes | No | High |
| **Context Splitting** | Indirectly | Yes | No (per-context) | Yes | High |

### Recommended Combinations

For a growing DCB-based Reventless application:

1. **Start with**: Structural chapters (folder organization, already built into plugin structure) + Swimlane organization (already built) + Event type subsetting (formalize in specs)
2. **When breadth becomes an issue**: Consider multiple DcbEventLogs or context splitting — but only when cross-entity consistency is truly not needed across the split
3. **When depth becomes an issue**: Add temporal chapters (entity-level, Option B) for long-lived entities with natural business lifecycle boundaries
4. **As a last resort**: Infrastructure snapshots for entities where temporal chapters don't fit (no natural temporal boundary)

---

## Relationship to DCB EventLog Partitioning

The analysis in [dcb-eventlog-partitioning-improvement.md](dcb-eventlog-partitioning-improvement.md) recommends moving from the current single-partition design (`id="dcb"`) to **primary-tag partitioning** (`id="<tagKey>:<tagValue>"`), where each entity gets its own DynamoDB partition. This architectural change has profound implications for how temporal chapters would work in DCB.

### How Partitioning Changes the Temporal Chapter Landscape

#### The Single-Partition World (Current)

In the current design, all events live in one DynamoDB partition keyed by `id="dcb"`. Temporal chapters must be implemented as tagged events within this flat log. Finding the latest `ChapterOpened` event for an entity requires a secondary index query. The shared partition means chapter-closing writes for one entity compete with regular command writes for all other entities.

#### The Primary-Tag-Partitioned World (Recommended)

With primary-tag partitioning, each entity already has its own physical partition (e.g., `id="productId:prod-1"`). This changes everything:

1. **Entity-level chapters become trivial to locate.** Finding the latest `ChapterOpened` event is a simple backward scan within the entity's own partition — no secondary index needed.

2. **Option A (global log chapters) becomes irrelevant.** There is no longer a single global log to segment.

3. **Option B (entity-level chapters) aligns perfectly.** Each entity's partition contains only that entity's events. The `~after` position parameter works directly — `after: <ChapterOpened position>` skips all pre-chapter events within the partition.

4. **Option C (hybrid with log rotation) simplifies to partition archival.** Individual entity partitions can be archived independently.

### Synergies Between Partitioning and Temporal Chapters

| Concern | Single Partition + Chapters | Primary-Tag Partition + Chapters |
|---------|---------------------------|----------------------------------|
| **Finding latest chapter** | Secondary index query across all events | Backward scan within entity partition |
| **Chapter closing atomicity** | Competes with all writers | DynamoDB transaction within one partition (atomic) |
| **Archival granularity** | Must archive entire log or nothing | Archive per-entity partition independently |
| **Concurrency during transition** | High risk — all entities share one partition | Low risk — only that entity's commands contend |

### The Chapter-Closing Operation Under Partitioning

DynamoDB transactions can atomically read-check-write within a single partition (up to 100 items). This directly enables **atomic chapter closing**:

```
TransactWriteItems (within partition "productId:prod-1"):
  1. ConditionCheck: no events after current head position
  2. Put: ChapterClosed { summary: { ... } }
  3. Put: ChapterOpened { carryForward: { ... } }
```

This eliminates the race condition concern. Without partitioning, chapter closing in the shared log competes with all writers. With partitioning, it only competes with commands for the same entity — and the transaction makes it atomic.

### Revised Recommendation

Given the partitioning analysis, the recommended approach for DCB temporal chapters simplifies to:

1. **Implement primary-tag partitioning first** (as recommended in the partitioning analysis)
2. **Then add entity-level temporal chapters (Option B)** as simple per-partition events — no special infrastructure beyond the partition itself
3. **Skip Option A entirely** — global log chapters are incompatible with partitioned storage
4. **Option C reduces to per-partition archival** — archive dormant entity partitions to cold storage

This sequencing means temporal chapters become a lightweight addition on top of partitioning, rather than a complex standalone feature.

---

## Implementation: What Has to Be Built

Structural chapters (folder organization, swimlanes, PPX conventions) are already fully supported. The following phases concern **temporal chapters (closing the books)** only.

### For Aggregate-Based Temporal Chapters

#### Phase A1: Aggregate Chapter Support

1. **Extend `Aggregate.Spec` (optional fields)**
   - `type summary` — the carry-forward state type
   - `summarySchema: S.t<summary>` — summary schema for serialization
   - `initFromSummary: summary => state` — initialize from a chapter opening
   - `toSummary: state => summary` — compute summary for chapter closing

2. **Modify `EventLog_Operations.replay`**
   - Add `~fromLatestChapter: bool=?` parameter
   - When enabled, scan for the latest `ChapterOpened` event and replay from there
   - Requires a convention or marker for chapter events within the aggregate's event union

3. **Chapter closing command**
   - A built-in command that triggers chapter closing for an aggregate instance
   - Reads current state, computes summary, appends `ChapterClosed` + `ChapterOpened`
   - Could be an automation or a manual trigger

### For DCB-Based Temporal Chapters

> **Prerequisite**: DCB temporal chapters should be implemented **after** primary-tag partitioning (see [dcb-eventlog-partitioning-improvement.md](dcb-eventlog-partitioning-improvement.md)). The phases below assume partitioning is already in place.

#### Phase D1: Foundation

1. **Chapter event convention in DcbEventLog**
   - Define how chapter events are represented in the event union
   - Option: Infrastructure meta-events (separate from domain events, special `TAG` prefix)
   - Option: Domain events with a chapter marker tag (e.g., `tag_chapter: "open"`)

2. **Chapter-aware `DcbEventLog.read`**
   - Enhance the read operation to optionally start from the latest chapter opening
   - With primary-tag partitioning, finding the latest `ChapterOpened` is a backward scan within the entity's own partition
   - The existing `~after` parameter provides the interface — the adapter finds the chapter start position internally

#### Phase D2: StateChangeSlice Integration

3. **StateChangeSlice chapter support**
   - Extend `StateChangeSlice.Spec` with optional:
     - `type summary` — the carry-forward state type
     - `initFromSummary: summary => decisionModel` — initialize from a chapter opening
     - `toSummary: decisionModel => summary` — compute summary for chapter closing
   - Modify `StateChangeSlice_Builder` to use chapter-aware reads when summary types are defined
   - The PPX (`@@reventless.spec` on slice files) could auto-detect `type summary` presence and generate appropriate wiring

4. **Chapter closing automation slice**
   - A new automation or scheduled slice that closes chapters
   - Must handle the read-compute-append cycle atomically
   - Must handle concurrency during the closing window

#### Phase D3: Storage Optimization

5. **Archival adapter**
   - `DcbEventLog` adapter extension for archiving closed chapters to cold storage (S3)
   - DynamoDB TTL configuration for pre-chapter events
   - Archive reader for cross-chapter queries and read model rebuilds

6. **In-memory adapter support**
   - Update `DcbEventLogStorage_InMemory` to support chapter-aware reads
   - Chapter position index in memory for testing

### Estimated Scope

| Phase | Components Affected | Complexity |
|-------|-------------------|------------|
| Structural chapters | None — already implemented via PPX + generate-plugin | Done |
| A1 (Aggregate temporal chapters) | `reventless-spec`, `EventLog`, `Aggregate` | Medium |
| D1 (DCB foundation) | `reventless-spec`, `DcbEventLog`, adapters | Low-Medium (after partitioning) |
| D2 (DCB slice integration) | `StateChangeSlice`, `StateChangeSlice_Builder` | High |
| D3 (Storage optimization) | `reventless-aws`, `reventless-in-memory` | Medium |

### Open Questions (Temporal Chapters Only)

1. **Should temporal chapters be transparent to domain logic?** If chapter events are infrastructure-level, domain slices don't need to know about them. But this requires the framework to handle carry-forward automatically, which means the framework needs to understand domain state shapes.

2. **Is the carry-forward state the same as the decision model?** In many cases yes, but some decision models include derived/computed fields that don't need to be persisted. The `summary` type might be a subset of `decisionModel`.

3. **Can temporal chapters work without explicit domain modeling?** An infrastructure-only approach could periodically snapshot the result of replaying all events for an entity and store it as a synthetic `ChapterOpened` event. This is effectively an automatic snapshot mechanism — simpler but less aligned with domain concepts.

4. **What's the minimum viable temporal chapter?** Perhaps starting with just entity-level chapter events and position-based skipping (Phase D1 + partial D2) delivers most of the performance benefit without the full archival infrastructure.

5. **Multiple DcbEventLogs vs. temporal chapters**: For a plugin where some entity groups are truly independent, is splitting into multiple logs a better first step than implementing temporal chapters? It's simpler to implement and may defer the need for temporal chapters entirely.

6. **How does this interact with cross-entity DCB queries?** A StateChangeSlice that reads events from multiple entities would need chapter positions for each entity. The query complexity increases.

---

## Related Analyses

- [event-modeling-json-reventless-conversion.md](event-modeling-json-reventless-conversion.md) — How the Dilger JSON schema maps to Reventless components. Neither chapter type is represented in the JSON schema: structural chapters round-trip via `slice.context` dotted naming convention; temporal chapters are entirely absent and must be added manually post-import.

---

## References

- [Event Modeling: What is it?](https://eventmodeling.org/posts/what-is-event-modeling/) — Core event modeling concepts
- [Event Modeling Cheat Sheet](https://eventmodeling.org/posts/event-modeling-cheatsheet/) — Building blocks and patterns
- [Implementing Closing the Books pattern](https://event-driven.io/en/closing_the_books_in_practice/) — Oskar Dudycz's practical guide
- [Keep your streams short! Temporal modeling for fast reads](https://www.kurrent.io/blog/keep-your-streams-short-temporal-modelling-for-fast-reads-and-optimal-data-retention) — Kurrent/EventStoreDB perspective
- [Should you always keep streams short?](https://event-driven.io/en/should_you_always_keep_streams_short/) — Nuanced take on stream length
- [The Snapshot Paradox](https://docs.eventsourcingdb.io/blog/2026/03/02/the-snapshot-paradox/) — Snapshots as events, not database shortcuts
- [How to Model Event-Sourced Systems Efficiently](https://www.kurrent.io/blog/how-to-model-event-sourced-systems-efficiently/) — Stream modeling best practices
- [Understanding Eventsourcing](https://www.eventsourcingbook.com/) — Martin Dilger's comprehensive book
- [Dynamic Consistency Boundary](https://dcb.events/) — DCB specification and concepts
- [DCB: Aggregates](https://dcb.events/topics/aggregates/) — How DCB relates to traditional aggregates
- [DCB in Axon Framework 5](https://www.axoniq.io/blog/dcb-in-af-5) — Practical DCB implementation
- [Confluent: Identifying and Integrating Event Streams](https://developer.confluent.io/courses/event-modeling/event-streams/) — Stream identification in event modeling
- [DCB EventLog Partitioning Improvement](dcb-eventlog-partitioning-improvement.md) — Related analysis on moving from single-partition to primary-tag partitioning
