# Hybrid Approach Improvements Plan

Source: [hybrid-aggregate-dcb-approach.md](../analysis/done/hybrid-aggregate-dcb-approach.md), Section 5.2

This plan implements the three potential improvements identified in the hybrid analysis. They are independent and can be done in any order.

---

## Step 1: ReadModel Sourcing from DCB EventTopic ✅

**Goal:** Allow a traditional `ReadModel` to subscribe to a DCB event log's `EventTopic` in addition to aggregate `EventTopic`s, so a single ReadModel can project events from both sources.

### Implementation

**Plugin_Builder.res** (line ~462): After building aggregate EventTopics, the DCB EventTopic is merged into `allEventTopics` under the key `<pluginName> ++ "DcbEventLog"` (e.g., `"CatalogDcbEventLog"`). This matches the existing `eventLogEntries` busKey convention (line 412).

```rescript
let allEventTopics = Aggregate.allEventTopics(aggregatesWithoutEventMappers)
switch dcbEventLogOutputs {
| Some(dcbOutputs) => allEventTopics->Dict.set(name ++ "DcbEventLog", dcbOutputs.eventTopic)
| None => ()
}
```

No changes needed to `ReadModel_Builder.res`, `Projection.res`, or `EventCollector` — they all work with `Dict<string, EventTopic.outputs>` and don't care about source origin.

A ReadModel that wants to consume DCB events simply defines a Mapping module whose `sourceName` matches the DCB key:

```rescript
module CatalogDcbMapping = {
  let sourceName = "CatalogDcbEventLog"  // <pluginName> ++ "DcbEventLog"
  @schema type sourceEvent = CatalogEventLog.event
  // ...
}
```

---

## Step 2: Hybrid Documentation in Platform-and-Plugin Guide ✅

**Goal:** Add a hybrid composition section to `docs/guides/platform-and-plugin-guide.md`.

### Implementation

Added "Part 3: Hybrid Composition" at the end of the guide, covering:

- **When to Use Each Approach** — decision criteria table
- **Hybrid Plugin Composition** — `Plugin.make` with both `~aggregates` and `~dcbSpec`, code example
- **ReadModel Sourcing from DCB EventTopic** — `sourceName` convention, mixed-source Mapping example
- **Extension Points in Hybrid Plugins** — same adapter pattern, source-transparent
- **Directory Layout** — folder structure mixing Aggregate/ and StateChangeSlice/
- **Reference Example** — links to `examples/online-shop-hybrid/`

---

## Step 3: Hybrid Example Tests — Partially Done

### Current Test Coverage

The hybrid example has:
- **CategoryBehaviorTest.res** — aggregate behavior tests ✅
- **CustomerBehaviorTest.res** — aggregate behavior tests ✅
- **ProductDecisionTest.res** — DCB decision logic (reduce + decide) ✅
- **OrderDecisionTest.res** — DCB decision logic (PlaceOrder, ShipOrder, CancelOrder) ✅
- **CatalogE2ETest.res** — E2E: dispatches DCB commands, verifies event count ✅
- **OrderingE2ETest.res** — E2E: dispatches DCB commands, verifies event count ✅

### Analysis 5.2.3 Test Scenarios

#### 3.1 Aggregate commands work independently of DCB state ✅ (covered implicitly)

Aggregate behavior tests (CategoryBehaviorTest, CustomerBehaviorTest) run in complete isolation from DCB — they use `BehaviorTest.Make` which creates a standalone aggregate with its own event log. DCB E2E tests (CatalogE2ETest, OrderingE2ETest) operate independently. Both coexist in the same package and pass, demonstrating no interference.

#### 3.2 DCB decision models correctly filter events across entity types ✅

**Resolution:** The framework already supports multi-clause queries via `DcbTag.buildQueryFromCommand`. When a command field uses `array<@s.matches(DcbTag.string) string>`, the function automatically switches to cross-entity mode — generating one OR clause per array element plus the scalar tagged fields. The in-memory storage's `matchesQuery` uses OR semantics across clauses (AND within each clause).

PlaceOrder uses `productId: array<@s.matches(DcbTag.string) string>` to generate multi-clause queries that fetch both Order events (via orderId tag) and CatalogProduct events (via each productId tag). The E2E test verifies:

1. PlaceOrder with un-synced product → rejected with `ProductsNotAvailable`
2. After syncing the missing product → PlaceOrder succeeds

#### 3.3 Extension points bridge aggregate events AND DCB events ⏳ (deferred)

Requires full Plugin.make setup with in-memory platform, which is complex. Lower priority — the mechanism is the same as pure-DCB extension points, verified by existing DCB example tests.

#### 3.4 Unified GraphQL schema includes both mutations ⏳ (deferred)

Requires GraphQL schema introspection or API component setup. Lower priority.

---

## Checklist

- [x] Step 1.1: Merge DCB EventTopic into allEventTopics in Plugin_Builder.res
- [x] Step 1.3: Add integration test for ReadModel with mixed sources
- [x] Step 2.1: Write hybrid composition section in platform-and-plugin-guide.md
- [x] Step 3.1: Test aggregate independence from DCB state (covered implicitly)
- [x] Step 3.2: Test cross-entity DCB decision model filtering
- [ ] Step 3.3: Test extension point bridging from both sources (deferred)
- [ ] Step 3.4: Test unified GraphQL schema (deferred)
