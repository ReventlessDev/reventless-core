# Chapters in Event Modeling: Analysis for Reventless

## What is a Chapter?

A **chapter** is a temporal segmentation pattern for event streams, closely related to (and often synonymous with) the **"Closing the Books"** pattern from accounting. The core idea is borrowed from double-entry bookkeeping: at the end of each period (month, quarter, year), accountants summarize all transactions into a closing balance, verify it, and use that summary as the opening balance for the next period. The full transaction history of prior periods is no longer needed for day-to-day operations.

Applied to event sourcing, a chapter represents a **bounded temporal segment** of an event stream with a defined beginning and end. Instead of maintaining a single ever-growing stream per entity or per domain, the stream is divided into discrete lifecycle periods — chapters — each opened by a domain event and closed by another.

### The Metaphor

Think of an entity's event history as a book. Without chapters, it is a single unbroken wall of text. With chapters, the narrative is segmented into meaningful periods. Each chapter:

- **Opens** with a summary event carrying forward the essential state from prior chapters
- **Contains** the events that occurred during that period
- **Closes** with a closing event that summarizes the chapter's final state

The closed chapter becomes immutable and archivable. The new chapter starts fresh with only the carried-forward summary, keeping the active working set small.

### Concrete Examples

| Domain | Chapter Boundary | Open Event | Close Event |
|--------|-----------------|------------|-------------|
| Cash Register | Cashier shift | `ShiftOpened(openingBalance)` | `ShiftClosed(closingBalance)` |
| Accounting | Monthly period | `MonthOpened(openingBalances)` | `MonthClosed(closingBalances)` |
| Hotel | Business day | `DayOpened(roomStates)` | `DayClosed(occupancyReport)` |
| Subscription | Billing cycle | `CycleStarted(plan, balance)` | `CycleCompleted(invoice)` |
| Inventory | Stock-take period | `PeriodOpened(currentStock)` | `PeriodClosed(reconciledStock)` |

## What is it Used For?

### 1. Performance — Keeping Streams Short

The primary motivation. When state is reconstructed by loading events and folding them, a stream with thousands of events becomes a performance bottleneck. Chapters ensure the active segment only contains events from the current period, typically tens to hundreds of events rather than thousands.

### 2. Data Retention and Archival

Closed chapters can be moved to cold storage (S3, archive tables) while the active chapter remains in the hot path. This is a natural fit for compliance requirements (GDPR right to erasure of old periods, regulatory retention windows).

### 3. Natural Business Boundaries

Many business processes have inherent temporal boundaries that chapters simply make explicit: fiscal periods, shifts, billing cycles, seasons. Making these boundaries first-class in the event model aligns the technical model with how the business thinks.

### 4. Schema Evolution

Shorter streams make schema migration easier. When a chapter closes, the summary event can be written using the latest schema version, eliminating the need to support reading old event formats within the active chapter.

### 5. Conflict Reduction

In high-contention scenarios, shorter event histories mean fewer events to check for optimistic concurrency conflicts, reducing the likelihood of retries.

## Advantages

1. **Bounded replay cost**: State reconstruction reads only the current chapter, with predictable and bounded event counts.

2. **Natural archival**: Closed chapters are immutable artifacts that can be compressed, moved to cold storage, or even deleted after a retention period.

3. **Domain alignment**: The model reflects real business concepts (shifts, periods, cycles) rather than being a purely technical concern.

4. **Simpler snapshots**: The chapter's opening summary event IS the snapshot — no separate snapshot infrastructure needed. Snapshots are events, not a database optimization hack.

5. **Cleaner schema evolution**: Each new chapter can adopt the latest schema version in its opening event.

6. **Reduced contention**: Shorter event histories have fewer events to check for concurrency conflicts.

## Consequences and Trade-offs

1. **Added modeling complexity**: Every entity needs explicit lifecycle analysis. The modeler must identify when chapters open and close, what state carries forward, and what gets left behind.

2. **Cross-chapter queries become harder**: Questions like "what happened to entity X across all time?" require reading multiple chapters or maintaining a separate all-time projection.

3. **Carry-forward logic is critical**: The summary/opening event must capture ALL state needed for the next chapter. Missing a field means that information is lost from the active working set (though still available in archived chapters).

4. **Chapter transition is a complex operation**: Closing one chapter and opening the next must be atomic or carefully orchestrated. Race conditions during transition can cause events to land in the wrong chapter.

5. **Not universally applicable**: Some entities don't have natural temporal boundaries (e.g., a user profile). Forcing artificial chapters on these can add complexity without clear benefit.

6. **Read model rebuild**: Rebuilding projections from scratch requires reading all chapters in sequence, not just the current one.

---

## Chapters in the Two Approaches: Aggregates vs. DCB

Reventless supports two fundamentally different event sourcing paradigms. Chapters apply to both, but the mechanics, trade-offs, and implementation strategies differ significantly.

### Recap: How the Two Approaches Differ

| Aspect | Aggregate-Based | DCB-Based |
|--------|----------------|-----------|
| **Event storage** | Per-aggregate-instance streams (partitioned by aggregate ID) | Single shared event log per bounded context |
| **Stream identity** | `(aggregateType, aggregateId)` → own stream | All events in one log, filtered by content tags |
| **State reconstruction** | Replay all events for one aggregate ID | Query tag-filtered events, build ephemeral decision model |
| **Concurrency** | Per-stream sequence number (implicit sharding) | Optimistic locking via conditional append on tag queries |
| **Consistency boundary** | Static — fixed to the aggregate | Dynamic — defined by each command's query |
| **Event scope** | Each aggregate type has its own event type | One event union per DcbEventLog, shared across all slices |

### Chapters for Aggregate-Based Event Sourcing

In the aggregate world, chapters are a **natural fit** because streams are already per-entity. The pattern maps directly:

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

### Chapters for DCB-Based Event Sourcing

In the DCB world, there are no per-entity streams to segment. The single shared event log and dynamic consistency boundaries create a fundamentally different challenge.

#### The Core Tension

DCB's power comes from **dynamic queries** — each StateChangeSlice reads exactly the events it needs via tag-based filtering. The consistency boundary is defined by the query, not by a stream. Chapters must work within this model without destroying its flexibility.

#### Option A: Global Log Chapters (Log-Level Segmentation)

The entire DcbEventLog is divided into temporal chapters:

```
Chapter 1: positions 0–10000 (2024-Q1)
Chapter 2: positions 10001–25000 (2024-Q2)
Chapter 3: positions 25001–current (2024-Q3)
```

Each chapter boundary includes **summary events** that carry forward the current state of all active entities. StateChangeSlices only query within the current chapter.

**Pros**: Simple conceptually. Bounded read windows. Clear archival boundaries.
**Cons**: Summary events must capture state for ALL entities — potentially very large. Chapter transitions affect the entire system. Doesn't align well with per-entity lifecycles. A single entity with high activity forces global chapter rotation.

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

A key DCB strength is that a StateChangeSlice can read events from **multiple entities** in a single query. For example, an `AddProduct` slice might check both product existence AND category existence before allowing a product to be added. With chapters, each entity may be at a different chapter boundary. The StateChangeSlice must:
- Find the latest `ChapterOpened` for each entity involved in the query
- Use the earliest of those positions as its `after` cursor
- Or maintain a separate chapter index per entity and merge results

This is significantly more complex than the aggregate case where each entity has its own isolated stream.

### Comparison: Chapters in Both Approaches

| Aspect | Aggregates | DCB |
|--------|-----------|-----|
| **Stream to segment** | Per-entity stream (natural unit) | Shared log (no natural per-entity boundary) |
| **Chapter scope** | Single entity, single aggregate type | Must choose: global, per-entity, or hybrid |
| **Implementation complexity** | Low — contained within aggregate component | High — cross-cutting concern touching DcbEventLog, all slices |
| **Carry-forward state** | Aggregate state (well-defined, single type) | Decision model per slice (multiple slices may need different summaries for the same entity) |
| **Cross-entity impact** | None — chapters are per-aggregate | Significant — cross-entity queries must reconcile chapter boundaries |
| **Event union impact** | None — chapter events can be separate from domain events | Chapter events must be part of the shared event union or handled as meta-events |
| **Concurrency during transition** | Low risk — per-entity stream isolation | High risk — chapter closing for one entity may conflict with commands from other slices |
| **When it makes sense** | Long-lived aggregates with many events | Large shared logs with entities that accumulate many events |

### Commonalities

Despite the different mechanics, both approaches share:

1. **The same domain modeling question**: What state needs to carry forward? This is a domain design decision regardless of the technical approach.

2. **The same schema evolution benefit**: Chapter boundaries are natural points to introduce new schema versions.

3. **The same archival pattern**: Closed chapters → cold storage → active chapter stays hot.

4. **The same lifecycle analysis requirement**: The modeler must identify natural temporal boundaries in the business domain.

5. **The same read model concern**: Projections/EventCollectors need access to full event history across chapters for rebuilds, regardless of whether the write side uses aggregates or DCB.

---

## Alternative Approaches to Structuring Events

Chapters are one way to manage growing event histories and organize slices, but they are not the only approach. Especially in DCB-based systems where a single event log can serve dozens of slices, the question of **how to structure and organize events** has multiple dimensions.

### The DCB Structuring Problem

In a DCB-based Reventless application, the event log grows along two axes:

1. **Depth**: More events per entity over time (the chapter problem)
2. **Breadth**: More entity types and slices sharing the same log (the organization problem)

The current Reventless DCB example (`online-shop-dcb`) already shows this: the Catalog plugin has one `CatalogEventLog` containing events for Products, Categories, AND ProductDemand — with 8 StateChangeSlices, 3 StateViewSlices, and translation slices all operating on the same log. As the domain grows, this single event union becomes a wide, complex type.

The following approaches address different aspects of this problem. They are not mutually exclusive — many can be combined.

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
- Slices only subscribe to the events they care about
- Reduced secondary index breadth — fewer tag types per log

**Cons**:
- **Loses cross-entity consistency** — the core DCB advantage. If `AddProduct` needs to check category existence, and category events are in a different log, the conditional append can't span both logs. The consistency boundary is limited to a single log.
- More infrastructure to manage — multiple DynamoDB tables, more Pulumi resources
- Cross-log queries require a separate coordination mechanism (similar to cross-plugin extension points)

**When to use**: When entities within a plugin are truly independent and rarely need cross-entity consistency guarantees. This is essentially using DCB at the micro level (per-area) rather than the macro level (per-plugin).

**Reventless impact**: Already supported — a plugin can have multiple `DcbEventLog` instances. The trade-off is that slices reading from different logs cannot share a consistency boundary.

### Approach 2: Hierarchical Tag Namespaces

Instead of splitting logs, use **hierarchical tag conventions** to organize events within a single log:

```
Tags:
  domain:product / entity:prod-1
  domain:category / entity:cat-1
  domain:demand / entity:prod-1
```

Slices query with domain-prefixed tags. The log remains shared (preserving cross-entity consistency) but events are logically partitioned by a tag namespace.

**Pros**:
- Single log — full DCB consistency preserved
- Organizational clarity without infrastructure changes
- secondary index queries can use the domain tag for pre-filtering

**Cons**:
- Doesn't solve the growing event union problem (all events still in one type)
- Doesn't help with depth (event accumulation over time)
- Tag proliferation — more tags per event, more secondary index columns

**When to use**: When you need cross-entity consistency but want better logical organization. Good for documentation and developer orientation, less impactful for runtime performance.

**Reventless impact**: Purely a convention — no framework changes needed. Could be formalized with a `DcbTag.namespace` helper.

### Approach 3: Event Categorization by Slice Type (Swimlanes)

Organize slices and their events by **slice type** rather than by entity:

```
Write slices (StateChangeSlices):
  Command handling → produces events

Read slices (StateViewSlices):
  Event projection → produces query results

Automation slices:
  Event → Command (internal automation)

Translation slices:
  External events → Internal commands (inbound)
  Internal events → External commands (outbound)
```

This is the **event modeling swimlane** approach, where the event model diagram organizes slices into horizontal lanes by their pattern type (Command, View, Automation, Translation). Each lane represents a different concern.

**Pros**:
- Aligns with event modeling methodology
- Clear separation of responsibilities
- Natural team boundaries — write-side team vs. read-side team
- Already reflected in Reventless' `Plugin.DcbSpec` structure (separate arrays for stateChangeSlices, stateViewSlices, automationSlices, translationSlices)

**Cons**:
- Organizational only — doesn't affect runtime event storage or performance
- Doesn't address event depth or log growth
- Doesn't help with the event union size

**When to use**: Always — this is a modeling/organizational pattern, not a runtime optimization. It helps developers navigate large systems.

**Reventless impact**: Already implemented in the plugin structure. Could be enhanced with better documentation and tooling.

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

Each StateChangeSlice declares which event types it reads and writes. The framework uses this declaration to optimize queries (only fetch matching event types) and to provide type safety (the `reduce` function only handles relevant events).

**Pros**:
- Type-safe — each slice only sees events it understands
- Query optimization — tag queries include `eventTypes` filter
- Documentation — explicit dependencies between slices and events
- Composability — adding a new event type doesn't affect unrelated slices

**Cons**:
- Requires a mapping between the full event union and per-slice subsets
- ReScript's type system makes this verbose (variant subsetting isn't native)
- The DCB read still returns the full union — filtering happens at the framework level

**When to use**: As systems grow beyond a handful of slices and the event union exceeds ~15-20 variants.

**Reventless impact**: Partially supported — `DcbTag.query` already accepts `eventTypes` for filtering. Could be formalized in `StateChangeSlice.Spec` as a required declaration.

### Approach 5: Snapshots as a Technical Optimization

Rather than the domain-driven chapter approach, use **infrastructure-level snapshots** that are transparent to domain logic:

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

**Pros**:
- Transparent to domain logic — no changes to specs, behaviors, or slices
- Solves the depth problem without requiring lifecycle modeling
- Can be added/removed without changing the event model
- Works for entities without natural temporal boundaries

**Cons**:
- Separate infrastructure (snapshot store, background process, consistency management)
- Snapshots can become stale if the background process falls behind
- Schema changes require snapshot invalidation and rebuild
- Not a domain concept — purely technical debt management
- "Snapshots solve a problem that rarely exists" — the performance concern often doesn't materialize until very high event counts

**When to use**: As a last resort for performance optimization, after domain modeling (chapters) and query optimization (secondary index tuning) have been exhausted.

**Reventless impact**: Requires new infrastructure — snapshot store adapter, background snapshot builder, snapshot-aware read operations. A significant cross-cutting change.

### Approach 6: Event Log per Bounded Context with Cross-Context Extensions

This is the approach Reventless already takes at the **plugin level**: each plugin has its own DcbEventLog (or set of aggregates), and cross-plugin communication happens via extension points.

The question is whether this pattern should be applied **within** a plugin as well — splitting one plugin into smaller bounded contexts, each with its own event log, connected by internal extension points.

```
CatalogPlugin/
  ProductContext/
    ProductEventLog
    AddProduct (StateChangeSlice)
    ProductsView (StateViewSlice)
  CategoryContext/
    CategoryEventLog
    AddCategory (StateChangeSlice)
    CategoriesView (StateViewSlice)
  Integration/
    ProductCategoryExtension (ensures product's category exists)
```

**Pros**:
- Maximum isolation between concerns
- Each context scales independently
- Clean bounded context boundaries within a plugin

**Cons**:
- Loses the DCB single-log consistency guarantee across contexts
- More infrastructure overhead
- Cross-context consistency requires eventual consistency patterns (extension points, sagas)
- May be over-engineering for a small domain

**When to use**: When a plugin has grown large enough that different entity types truly represent separate bounded contexts with independent lifecycles.

**Reventless impact**: Already supported — a plugin can contain multiple DcbEventLogs and extension points. The trade-off is architectural complexity.

### Comparison Matrix

| Approach | Addresses Depth | Addresses Breadth | Preserves DCB Consistency | Domain-Driven | Implementation Effort |
|----------|:-:|:-:|:-:|:-:|:-:|
| **Chapters** | Yes | No | Depends on option | Yes | High |
| **Multiple Logs** | No | Yes | No (per-log only) | Somewhat | Medium |
| **Tag Namespaces** | No | Yes (logical) | Yes | No | Low |
| **Swimlanes** | No | Yes (organizational) | N/A | Yes | Already done |
| **Event Subsetting** | No | Yes (type safety) | Yes | Somewhat | Medium |
| **Snapshots** | Yes | No | Yes | No | High |
| **Context Splitting** | Indirectly | Yes | No (per-context) | Yes | High |

### Recommended Combinations

For a growing DCB-based Reventless application:

1. **Start with**: Swimlanes (already built into plugin structure) + Event type subsetting (formalize in specs)
2. **When depth becomes an issue**: Add chapters (entity-level, Option B) for long-lived entities
3. **When breadth becomes an issue**: Consider multiple DcbEventLogs or context splitting — but only when cross-entity consistency is truly not needed across the split
4. **As a last resort**: Infrastructure snapshots for entities where chapters don't fit (no natural temporal boundary)

---

## Relationship to DCB EventLog Partitioning

The analysis in [dcb-eventlog-partitioning-improvement.md](dcb-eventlog-partitioning-improvement.md) recommends moving from the current single-partition design (`id="dcb"`) to **primary-tag partitioning** (`id="<tagKey>:<tagValue>"`), where each entity gets its own DynamoDB partition. This architectural change has profound implications for how chapters would work in DCB — it largely resolves the "core tension" described above and makes entity-level chapters (Option B) the natural and clearly preferred approach.

### How Partitioning Changes the Chapter Landscape

#### The Single-Partition World (Current)

In the current design, all events live in one DynamoDB partition keyed by `id="dcb"`. Chapters must be implemented as tagged events within this flat log. Finding the latest `ChapterOpened` event for an entity requires a secondary index query. The shared partition means chapter-closing writes for one entity compete with regular command writes for all other entities. This is the world where Options A, B, and C all have significant trade-offs.

#### The Primary-Tag-Partitioned World (Recommended)

With primary-tag partitioning, each entity already has its own physical partition (e.g., `id="productId:prod-1"`). This changes everything:

1. **Entity-level chapters become trivial to locate.** Finding the latest `ChapterOpened` event is a simple backward scan within the entity's own partition — no secondary index needed, no cross-partition query. The partition is already scoped to the entity.

2. **Option A (global log chapters) becomes irrelevant.** There is no longer a single global log to segment. Each entity partition is its own mini-log. Global chapter boundaries would require coordinating across all partitions — the opposite of what partitioning achieves.

3. **Option B (entity-level chapters) aligns perfectly.** Each entity's partition contains only that entity's events. A `ChapterOpened`/`ChapterClosed` event pair within the partition naturally segments it. The `~after` position parameter works directly — `after: <ChapterOpened position>` skips all pre-chapter events within the partition.

4. **Option C (hybrid with log rotation) simplifies to partition archival.** Instead of rotating a global log, individual entity partitions can be archived independently. A partition with only closed chapters and no recent activity can be moved to cold storage while active partitions remain hot.

### Synergies Between Partitioning and Chapters

| Concern | Single Partition + Chapters | Primary-Tag Partition + Chapters |
|---------|---------------------------|----------------------------------|
| **Finding latest chapter** | secondary index query across all events | Backward scan within entity partition |
| **Chapter closing atomicity** | Competes with all writers | DynamoDB transaction within one partition (atomic) |
| **Archival granularity** | Must archive entire log or nothing | Archive per-entity partition independently |
| **Chapter position index** | Dedicated table/secondary index required | Not needed — partition IS the index |
| **Cross-entity decision models** | Chapter positions from multiple entities via secondary index | Each entity's partition queried independently; chapter position found per-partition |
| **Concurrency during transition** | High risk — all entities share one partition | Low risk — only that entity's commands contend |

### Impact on Chapter Implementation Phases

The partitioning analysis proposes a phased migration (Phases 1–4 in the partitioning doc). Chapter implementation should be **sequenced after** partitioning, because partitioning dramatically simplifies chapters:

- **Phase D1 (Chapter foundation)** becomes easier: no chapter position index needed — the entity partition provides it natively. The `DcbEventLog.read(~query, ~after)` interface already works per-partition.

- **Phase D2 (StateChangeSlice integration)** is unchanged: the slice spec still needs `summary`/`initFromSummary`/`toSummary`. But the runtime implementation is simpler because finding the chapter start is a local partition operation.

- **Phase D3 (Storage optimization)** aligns with partitioning's archival story: per-entity partitions with only closed chapters can be archived to S3 using DynamoDB's export or TTL. No need for a separate archival mechanism beyond what partitioning already enables.

### The Chapter-Closing Operation Under Partitioning

The partitioning analysis shows that DynamoDB transactions can atomically read-check-write within a single partition (up to 100 items). This directly enables **atomic chapter closing**:

```
TransactWriteItems (within partition "productId:prod-1"):
  1. ConditionCheck: no events after current head position
  2. Put: ChapterClosed { summary: { ... } }
  3. Put: ChapterOpened { carryForward: { ... } }
```

This eliminates the race condition concern from the chapter analysis. Without partitioning, chapter closing in the shared log competes with all writers. With partitioning, it only competes with commands for the same entity — and the transaction makes it atomic.

### Cross-Entity Decision Models: Already Addressed

The partitioning analysis identifies cross-entity queries as rare and recommends secondary index-based fallback or targeted single-partition reads. The same applies to cross-entity chapter concerns:

- If a StateChangeSlice queries multiple entities, each entity's partition is queried independently. Each query can independently skip to the latest chapter opening within its partition.
- The k-way merge infrastructure (already described in the partitioning doc) handles merging results across partitions, respecting per-partition chapter boundaries.
- No need for a unified cross-entity chapter index — each partition manages its own chapters.

### Revised Recommendation

Given the partitioning analysis, the recommended approach for DCB chapters simplifies to:

1. **Implement primary-tag partitioning first** (as recommended in the partitioning analysis)
2. **Then add entity-level chapters (Option B)** as simple per-partition events — no special infrastructure beyond the partition itself
3. **Skip Option A entirely** — global log chapters are incompatible with partitioned storage
4. **Option C reduces to per-partition archival** — archive dormant entity partitions to cold storage, no need for a separate log rotation mechanism

This sequencing means chapters become a lightweight addition on top of partitioning, rather than a complex standalone feature built against the current single-partition design.

---

## Implementation: What Has to Be Built

### For Aggregate-Based Chapters

#### Phase A1: Aggregate Chapter Support

1. **Extend `Aggregate.Spec` (optional fields)**
   - `type summary` — the carry-forward state type
   - `summarySchema: S.t<summary>` — sury schema for serialization
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

### For DCB-Based Chapters

> **Prerequisite**: DCB chapters should be implemented **after** primary-tag partitioning (see [dcb-eventlog-partitioning-improvement.md](dcb-eventlog-partitioning-improvement.md)). Partitioning gives each entity its own DynamoDB partition, which makes chapters a lightweight per-partition addition rather than a complex cross-cutting feature. The phases below assume partitioning is already in place.

#### Phase D1: Foundation

1. **Chapter event convention in DcbEventLog**
   - Define how chapter events are represented in the event union
   - Option: Infrastructure meta-events (separate from domain events, special `TAG` prefix)
   - Option: Domain events with a chapter marker tag (e.g., `tag_chapter: "open"`)

2. **Chapter-aware `DcbEventLog.read`**
   - Enhance the read operation to optionally start from the latest chapter opening
   - With primary-tag partitioning, finding the latest `ChapterOpened` is a backward scan within the entity's own partition — no separate index or secondary index needed
   - The existing `~after` parameter provides the interface — the adapter finds the chapter start position internally

#### Phase D2: StateChangeSlice Integration

4. **StateChangeSlice chapter support**
   - Extend `StateChangeSlice.Spec` with optional:
     - `type summary` — the carry-forward state type
     - `initFromSummary: summary => decisionModel` — initialize from a chapter opening
     - `toSummary: decisionModel => summary` — compute summary for chapter closing
   - Modify `StateChangeSlice_Builder` to use chapter-aware reads when summary types are defined

5. **Chapter closing automation slice**
   - A new automation or scheduled slice that closes chapters
   - Must handle the read-compute-append cycle atomically
   - Must handle concurrency during the closing window

#### Phase D3: Storage Optimization

6. **Archival adapter**
   - `DcbEventLog` adapter extension for archiving closed chapters to cold storage (S3)
   - DynamoDB TTL configuration for pre-chapter events
   - Archive reader for cross-chapter queries and read model rebuilds

7. **In-memory adapter support**
   - Update `DcbEventLogStorage_InMemory` to support chapter-aware reads
   - Chapter position index in memory for testing

### For Event Type Subsetting (Both Approaches)

8. **Formalize event type declarations in StateChangeSlice.Spec**
   - Required `let relevantEventTypes: array<string>` field
   - Framework uses this to optimize DcbTag queries
   - Type-level enforcement via a filtered variant type (aspirational — ReScript limitation)

### Estimated Scope

| Phase | Components Affected | Complexity |
|-------|-------------------|------------|
| A1 (Aggregate chapters) | `reventless-spec`, `EventLog`, `Aggregate` | Medium |
| D1 (DCB foundation) | `reventless-spec`, `DcbEventLog`, adapters | Low-Medium (after partitioning) |
| D2 (DCB slice integration) | `StateChangeSlice`, `StateChangeSlice_Builder` | High |
| D3 (Storage optimization) | `reventless-aws`, `reventless-in-memory` | Medium |
| Event subsetting | `StateChangeSlice.Spec`, `DcbEventLog_Operations` | Low-Medium |

### Open Questions

1. **Should chapters be transparent to domain logic?** If chapter events are infrastructure-level, domain slices don't need to know about them. But this requires the framework to handle carry-forward automatically, which means the framework needs to understand domain state shapes.

2. **How does this interact with cross-entity DCB queries?** A StateChangeSlice that reads events from multiple entities (e.g., checking both product and category existence) would need chapter positions for each entity. The query complexity increases.

3. **Is the carry-forward state the same as the decision model?** In many cases yes, but some decision models include derived/computed fields that don't need to be persisted. The `summary` type might be a subset of `decisionModel`.

4. **Can chapters work without explicit domain modeling?** An infrastructure-only approach could periodically snapshot the result of replaying all events for an entity and store it as a synthetic `ChapterOpened` event. This is effectively an automatic snapshot mechanism — simpler but less aligned with domain concepts.

5. **What's the minimum viable chapter?** Perhaps starting with just entity-level chapter events and position-based skipping (Phase D1 + partial D2) delivers most of the performance benefit without the full archival infrastructure.

6. **Should event subsetting be enforced or advisory?** Strict enforcement means a slice that doesn't declare its event types won't compile. Advisory means it's used for query optimization but the full union is still accessible. The former is safer; the latter is more pragmatic during early development.

7. **Multiple DcbEventLogs vs. chapters**: For a plugin where some entity groups are truly independent, is splitting into multiple logs a better first step than implementing chapters? It's simpler to implement and may defer the need for chapters entirely.

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
