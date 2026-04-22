# Event Source Connection Matrix — Architectural Analysis

## Background

This analysis documents all possible source → consumer connections in the Reventless framework, which connections are currently implemented, which are architecturally missing, and how the missing ones could be added. It was prompted by the conversion of `Platform_EventGraph` from a DCB `StateViewSlice` to a `ReadModel`, which surfaced a fundamental design question: what event sources can each component type subscribe to?

---

## Current Architecture

The framework has two parallel event-sourcing patterns, each with its own event log and topic:

| Pattern | Event Log | Event Topic | Writers | Readers |
|---------|-----------|-------------|---------|---------|
| **Aggregate** | per-aggregate DynamoDB table | SQS/SNS EventTopic | Aggregate command handler | ReadModel |
| **DCB** | shared DynamoDB table (tagged) | SQS/SNS DcbEventTopic | StateChangeSlice | StateViewSlice, AutomationSlice, OutboundTranslationSlice |

These two patterns currently form two isolated event pipelines. Events produced by an Aggregate never reach DCB consumers, and vice versa.

---

## Full Connection Matrix

### Implemented Connections ✓

| Source | Consumer | Mechanism |
|--------|----------|-----------|
| Aggregate EventTopic | ReadModel | EventCollector subscribes to `allEventTopics` filtered by `sourceNames` from Mappings |
| DcbEventLog EventTopic | StateViewSlice | EventCollector hardcoded to `Dict.fromArray([(Spec.name, dcbEventTopicOutputs)])` |
| DcbEventLog EventTopic | AutomationSlice | Same hardcoded single-source pattern |
| DcbEventLog EventTopic | OutboundTranslationSlice | Same hardcoded single-source pattern |
| External system | InboundTranslationSlice | Separate HTTP/queue entry point, no EventCollector |

### Missing Connections

| Source | Consumer | Status | Rationale |
|--------|----------|--------|-----------|
| DcbEventLog EventTopic | ReadModel | **Missing** | ReadModel only receives `allEventTopics` (Aggregate topics); DCB topics are a separate output |
| Aggregate EventTopic | StateViewSlice | **Not meaningful** | See note below |
| Aggregate EventTopic | AutomationSlice | **Missing** | AutomationSlice hardcoded to DCB only |
| DcbEventLog EventTopic | ReadModel | **Missing — high value** | Core subject of this analysis |

**Note on StateViewSlice ← Aggregate**: This connection is architecturally incoherent. StateViewSlice is a DCB concept; its consistency guarantees depend on events flowing through the DCB event log (tagged, queryable). An Aggregate EventTopic would bypass the event log entirely, removing DCB semantics. If you need an Aggregate event to update view state, a ReadModel is the correct component.

---

## The Missing High-Value Connection: ReadModel ← DCB EventLog

### What It Means

Today, a ReadModel can only be fed from Aggregate events. If you need a read model that answers questions spanning both Aggregate-sourced data and DCB-sourced data, you have no direct way to do it. The ReadModel projection cannot receive DCB events.

### Why It Makes Sense

ReadModel is fundamentally a projection sink: it consumes events from any source and builds queryable state. The restriction to Aggregate topics is an implementation accident, not a design principle. `EventCollector` already supports multiple source topics — `allEventTopics` is a `Dict` keyed by topic name. The DCB event log publishes to an EventTopic with the same interface as any Aggregate EventTopic. The plumbing to support this is almost already there.

### Use Cases

**1. Platform Event Graph (the case that triggered this analysis)**
The `PlatformEventGraph` read model shows Plugin topology (nodes/edges per plugin). Plugin is an Aggregate. But imagine future plugins that are fully DCB-based — their topology would come from StateChangeSlice events on the DCB log. A single read model should be able to draw the complete topology regardless of whether each plugin uses the Aggregate or DCB pattern.

**2. Order Fulfillment Dashboard**
An e-commerce system has:
- `Order` aggregate (EventLog-based) — produces `OrderPlaced`, `OrderShipped`, `OrderCancelled`
- `Inventory` StateChangeSlice (DCB-based) — produces `StockReserved`, `StockReleased`

A "Fulfillment" read model needs to correlate `OrderPlaced` with `StockReserved` for the same product. Currently impossible without a bridge; with mixed-source ReadModel it is a single projection.

**3. Audit / Compliance Log**
A compliance read model needs to record every significant state change system-wide: commands accepted by any Aggregate AND all DCB state transitions. Currently you'd need a separate ReadModel per source and then a merge layer, or an OutboundTranslationSlice that republishes DCB events onto a synthetic Aggregate topic.

**4. Cross-Pattern Analytics**
A metrics read model accumulates counters across both patterns. Example: "count all user-initiated actions today" where user actions can originate as Aggregate commands or DCB commands depending on the module. With mixed sources, one read model covers both.

**5. Hybrid-Platform Transition State**
During a migration where some entities are being moved from Aggregate to DCB pattern (or vice versa), a read model must accept events from both the old EventTopic and the new DCB topic to maintain continuity without a full replay. This is directly analogous to the `Platform_EventGraph` case: two generations of the same data on two different pipelines.

---

## How ReadModel ← DCB EventLog Could Be Implemented

### Option A: Pass DCB Event Topics into `allEventTopics`

The simplest approach. `ReadModel_Builder` already receives `allEventTopics` from the Platform. The Platform could also pass `dcbEventTopics` (one entry per DCB event log name). The builder merges them:

```rescript
// In ReadModel_Builder.Make
let allTopics = Dict.assign(allEventTopics, dcbEventTopics)
let eventTopics = allTopics->EventTopic.filter(sourceNames)
```

The Mappings module would declare DCB event sources alongside Aggregate sources. The `sourceNames` extraction from Mappings would naturally include DCB source names.

**Implications:**
- No change to EventCollector or the adapter layer
- No change to how events are decoded — DCB events are already plain JSON
- The only question is whether to distinguish DCB sources from Aggregate sources in `sourceNames` — probably not needed; topic name is sufficient

**Limitation:** Events in the DCB EventTopic are typed by the entire DCB spec, not per-slice. A ReadModel Mapping that wants only `StockReserved` events would need to pattern-match and `Ignore` other events. This is already how Aggregate ReadModels work (all events from the topic arrive; projection switches on event type).

### Option B: Dedicated `dcbMappings` Module Concept

Introduce a parallel `DcbMappings` module type alongside `Mappings`, where the source is `DcbEventLog.Spec` instead of an Aggregate spec. The builder wires both independently:

```rescript
module ReadModel = ReadModel_Builder.MakeWithDcb(
  Spec,
  AggregateMappings,   // existing
  DcbMappings,         // new
)
```

**Benefit:** Type-safe separation — Aggregate events and DCB events have different schemas and the compiler enforces this. You can't accidentally apply an Aggregate Mapping to a DCB event.

**Cost:** More functor plumbing; the Platform must thread both topic dictionaries through. Builder complexity increases.

### Option C: Event Bridge via OutboundTranslationSlice

Without any framework change, DCB events can be republished onto a synthetic Aggregate EventTopic via OutboundTranslationSlice → InboundTranslationSlice chain. The ReadModel then subscribes to that synthetic topic.

```
StateChangeSlice → DcbEventLog → OutboundTranslationSlice
                                        ↓ (publishes command)
                            InboundTranslationSlice → synthetic Aggregate EventTopic
                                                                ↓
                                                           ReadModel
```

**Benefit:** No framework change required today.

**Cost:** Significant operational overhead (two extra Lambda invocations per event, two extra queues, extra latency, extra cost). Also semantically awkward — DCB events become "commands" in the bridge, which is a conceptual mismatch.

### Recommended Approach

**Option A for immediate use cases, Option B for the full design.**

Option A is a small, low-risk change that unlocks mixed-source ReadModels immediately. Option B provides better type safety and is the right long-term design once the pattern is proven. Option C should be avoided — it trades architectural clarity for operational complexity.

---

## The Missing AutomationSlice ← Aggregate EventTopic Connection

AutomationSlice is currently hardcoded to DCB only (same pattern as StateViewSlice). But an AutomationSlice that reacts to Aggregate events and dispatches DCB commands is a legitimate use case:

**Use case:** When `OrderShipped` fires on the Shipping Aggregate, an AutomationSlice should trigger `NotifyCustomer` on a DCB-based Notification StateChangeSlice.

Today this requires: Aggregate EventTopic → ReadModel → (polling or trigger) → DCB command. With mixed-source AutomationSlice it could be direct.

**Implementation:** Same as Option A for ReadModel — pass Aggregate EventTopics into the AutomationSlice builder alongside `dcbEventTopicOutputs`. The `consumedEventSchema` would need to accept events from multiple source schemas, which requires a union schema or a separate decoded type.

This is higher complexity than ReadModel because AutomationSlice also needs to handle the DCB tagging context when deciding whether to produce a command (to maintain DCB consistency semantics). Whether an Aggregate-sourced event can meaningfully participate in a DCB decision model needs careful consideration per use case.

---

## Summary

| Connection | Status | Value | Effort | Recommended |
|-----------|--------|-------|--------|-------------|
| ReadModel ← DCB EventLog | Missing | High | Low (Option A) | Yes — implement Option A |
| ReadModel ← Multiple sources (both) | Missing | High | Low (extends Option A) | Yes |
| AutomationSlice ← Aggregate EventTopic | Missing | Medium | Medium | Future — evaluate per use case |
| StateViewSlice ← Aggregate EventTopic | Not meaningful | — | — | No |

The key insight from this session: the framework's two patterns (Aggregate + DCB) are currently isolated pipelines with no cross-connections on the consumer side. Adding the ReadModel ← DCB EventLog connection via Option A is a small, high-value change that enables cross-pattern projections and unblocks a real category of multi-source read models.
