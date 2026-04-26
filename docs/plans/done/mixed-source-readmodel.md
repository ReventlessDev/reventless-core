# Mixed-source ReadModel: DCB EventLog as a `Mapping` Source (Plan 03)

## Executive Summary

Let a `ReadModel` project events from both Aggregate `EventTopic`s and `DcbEventLog` `EventTopic`s in the same `Mapping.Make` registry. After this plan an application developer can write:

```rescript
// MyReadModel/Projections.res
module FromAggregate = Reventless.Projection.Mapping.Make(
  ProductSpec,                  // Aggregate spec module — works today
  MyReadModelSpec,
  { let project = e => ... },
)

module FromDcb = Reventless.Projection.Mapping.Make(
  CatalogDcbSource,             // NEW: DCB-source spec module — Plan 03 enables this
  MyReadModelSpec,
  { let project = e => ... },
)

let mappings = [module(FromAggregate), module(FromDcb)]
```

Both mappings target the same read-model state; the runtime dispatches each event to the right `project` function by `sourceName` matching, exactly as it does for multi-Aggregate ReadModels today.

## Reality Check: How Much Already Works

A code audit (summarized below) shows that **most of the runtime plumbing for DCB → ReadModel is already in place**. The original framing — "small, low-risk Option A change" — is correct, but most of the change is *not* in the builder. It is in the developer-facing surface.

### Already implemented

1. **DCB topic merged into `allEventTopics`.** `Plugin_Builder.res:246–252` already merges the DcbEventLog `EventTopic` into the per-plugin `allEventTopics` dict under the key `<pluginName>DcbEventLog`. Confirmed in code:

   ```rescript
   let allEventTopics = Aggregate.allEventTopics(aggregatesWithoutEventMappers)
   // Merge DCB EventTopic into allEventTopics so ReadModels can subscribe to DCB events.
   switch dcbResult.dcbEventLogOutputs {
   | Some(dcbOutputs) => allEventTopics->Dict.set(name ++ "DcbEventLog", dcbOutputs.eventTopic)
   | None => ()
   }
   let readModelsOutputs = readModels->createReadModels(~api, ~apiRole, allEventTopics, opts)
   ```

   The same merge exists in `admin/Platform_Admin.res:169–177`.

2. ~~**Events from the DCB log carry the right `service` name.**~~ — **Audit correction.** `DcbEventLog_Operations.res:18` sets `Message.generateMeta(~service=name)` where `name` is the **plain plugin name** (e.g. `"Catalog"`), NOT the dict key (`"CatalogDcbEventLog"`). The two do **not** match by construction. See `docs/analysis/done/mixed-source-readmodel-audit.md`. A new **Phase 1.5** is added below to fix this.

3. **Source dispatch by `sourceName` works.** `MapperNto1.findMappings` (`MapperNto1.res:57–63`) filters by `Mapping.sourceName == sourceName` from `context.meta.service`. No code path currently distinguishes Aggregate sources from DCB sources at dispatch time — both go through the same matcher.

4. **`ReadModel_Builder.Make` already accepts the merged dict.** No changes needed to its signature.

### What is missing

The gap is **developer-facing**:

5. **No concrete Source module exists for DCB events.** The `Projection.Source` module type (`reventless-spec/src/types/Projection.res:5–10`) requires `module Id: Id.T`, `let name: string`, and `@schema type event`. Aggregate spec modules satisfy this directly. The DcbEventLog component does *not* expose such a module — its events are typed as raw `{eventType: string, data: JSON.t, tags: array<DcbTag.tag>}` (`reventless-infra/src/components/DcbEventLog.res:13–17`). A developer who wants DCB-sourced projection has to hand-roll a Source-shaped module that describes the subset of DCB events they care about, with the right `name` to match the runtime `service` field.

6. **No example.** Zero existing projection files use DCB as a source. `Platform_EventGraphProjection.res` is single-Aggregate (Plugin); `online-shop-aggregates/.../ProductDemandProjections.res` is multi-Aggregate. The pattern is undocumented and unrehearsed.

7. **No end-to-end test.** Tests cover Aggregate→ReadModel projection thoroughly. There is no test driving an event through the DCB log into a ReadModel callback.

8. **No documentation.** No section in any guide describing how to project DCB events into a ReadModel.

The plan is therefore **mostly developer-facing** — an audit, a small framework helper, an example, a test, docs. The runtime change is minimal.

---

## Naming and Source Module Convention

A DCB-source spec module satisfies `Projection.Source`:

```rescript
// CatalogDcbSource.res — hand-written today; framework-provided helper after this plan.
let name = "CatalogDcbEventLog"               // matches <pluginName>DcbEventLog dict key
module Id = Reventless.Id.String

@schema
type event =
  | ProductAdded({productId: string, name: string, price: float})
  | ProductRenamed({productId: string, name: string})
  | ProductArchived({productId: string})
  // ... only the variants this consumer cares about
```

The convention:
- **`name` exactly equals `<pluginName>DcbEventLog`.** This is the Source's identity at dispatch time. A misspelled name silently produces "no events arriving" (the topic is filtered out before the callback ever runs) — see *Risks and Mitigations* below for the fail-fast change to detect this.
- **`type event` is a typed subset of the DCB log's combined events.** It does not have to enumerate every event ever produced on the log; only the variants this projection projects. Other variants (those defined by sibling slices the ReadModel doesn't care about) are decoded as parse errors and the runtime falls through to `Ignore` — same behavior as Aggregate ReadModels seeing unrelated event variants today.
- **`module Id`** is `Reventless.Id.String` for DCB sources (DCB events are content-addressed, no Aggregate-style stream id).

The framework can ship a small helper to build this module from a slice's `event` type or from a manually-curated subset, but the helper is not required — a hand-rolled module is enough to make the pattern work.

---

## Scope

### In scope

1. **Spec helper for DCB sources.** Add a `Reventless.Projection.DcbSource` module that constructs a Source-shaped module from a name and schema:

   ```rescript
   module CatalogDcbSource = Reventless.Projection.DcbSource.Make({
     let name = "CatalogDcbEventLog"
     @schema type event = ProductAdded(...) | ProductRenamed(...) | ...
   })
   ```

   This is essentially a renaming functor — it asserts the `Projection.Source` shape against an inline DCB event subset. The helper is a thin convenience over hand-rolling.

2. **Source-name validation at plugin assembly.** Add a check in `Plugin_Builder.Make` (or `createReadModels`) that every `Mapping.sourceName` resolves to a key in `allEventTopics`. Today a typo produces silent no-op behavior. After this change, a missing source name fails plugin assembly with a clear error.

3. **End-to-end example.** Add a hybrid example app under `examples/online-shop-hybrid/` (or extend the existing one) that demonstrates a multi-source ReadModel reading from one Aggregate and one DCB slice's events into a single state. This is also the regression vehicle for #2 and #5.

4. **End-to-end test.** A test in `reventless-in-memory/tests/` that:
   - Wires a ReadModel with one DCB-source mapping.
   - Drives a command through a StateChangeSlice that emits an event on the DCB log.
   - Asserts the event flows through the topic, lands in the ReadModel callback, and updates the projection.
   - Covers the rejection case from #2 (typo'd source name → plugin assembly fails).

5. **Source-name typo fail-fast.** When a `Mapping`'s `sourceName` doesn't match any topic in `allEventTopics`, raise a clear error at plugin assembly time. Today: the topic filter silently drops, the projection never runs, the dev sees zero events. After: the plugin won't start without a matching source.

6. **Documentation.** A short guide page on cross-pattern projection: when to use it, the `name` convention, the typed-subset pattern, the multi-Aggregate + DCB combination.

### Out of scope

- **No new module-type slot in `ReadModel_Builder.Make`.** This plan deliberately follows Option A: one runtime topic dict, sources distinguished only by name. A separate `DcbMappings` slot would cost every app dev — see [*Design Context: Option A vs Option B*](#design-context-option-a-vs-option-b) below for the rationale.
- **No changes to `EventCollector` or platform adapters.** The topic-name dispatch path already supports this.
- **No DCB event-schema synthesis.** Plan 03 leaves the developer in charge of declaring which DCB event variants they care about. Auto-synthesizing a per-plugin DCB Source module from slice events is a possible follow-up but adds PPX surface.
- **AutomationSlice cross-source consumption.** That is Plan 04. Plan 03 unblocks Plan 04's plumbing but does not implement it.

---

## Implementation Phases

### Phase 1 — Audit and confirm the plumbing

Before adding new code, validate that the steps in *Reality Check* §1–3 are exhaustive. Walk a synthetic event from a StateChangeSlice's `decide` through the topic, into a ReadModel callback, all the way to the `project` function. If anything is missing, that becomes Phase 1's actual scope.

Output: a one-page audit note summarizing the trace, attached to the plan PR. If gaps surface, file them as additional phases.

### Phase 1.5 — Align DCB `meta.service` with `allEventTopics` dict key (NEW)

Surfaced by Phase 1's audit. Without this fix, the entire plan is dead code.

Change `DcbEventLog_Operations.res` so the `service` it stamps onto every published event matches the key under which `Plugin_Builder` registers the topic in `allEventTopics`. Concretely:

- Add a `serviceName: string` field to `DcbEventLog_Operations.Ops` module type.
- Replace `Message.generateMeta(~service=name)` with `Message.generateMeta(~service=serviceName)`.
- Replace `Ops.publishJson(name, …)` with `Ops.publishJson(serviceName, …)` (the first arg is the in-memory bus's per-message `service` field; keeping the two in sync avoids a subtle log/dispatch divergence).
- In `DcbEventLog_Builder.res`, populate the new field as `serviceName = name ++ "DcbEventLog"` (matches `Plugin_Builder.res:250`).

Tests: extend `DcbEventLogOperationsTest` to assert that the published event's `meta.service` equals `<name>DcbEventLog`. Phase 4's E2E test exercises the end-to-end flow.

### Phase 2 — Source-name typo fail-fast

In `Plugin_Builder.Make` (or wherever ReadModels are assembled), iterate over each ReadModel's `Mappings.mappings` and assert every `Mapping.sourceName` is a key in `allEventTopics`. Raise on mismatch with a message naming the mapping, the source name it expected, and the available topic names.

This is a small change with big upside: today a misspelled DCB source produces silent no-op. The same protection benefits Aggregate sources too.

Tests: add a unit test (or assembly test) that wires a ReadModel with a bogus `sourceName` and asserts the error message.

### Phase 3 — `Reventless.Projection.DcbSource` helper

Add a small functor in `reventless-spec/src/types/Projection.res` (or a new file `DcbSource.res` in the same package):

```rescript
module DcbSource = {
  module type Definition = {
    let name: string
    @schema type event
  }
  module Make = (D: Definition): Source with type event = D.event => {
    module Id = Reventless.Id.String
    let name = D.name
    @schema type event = D.event
  }
}
```

The helper exists purely for ergonomics — `module CatalogDcbSource = Projection.DcbSource.Make({...})` reads more naturally than hand-rolling the full Source shape. It is not strictly necessary; the documentation includes both forms.

### Phase 4 — End-to-end test in `reventless-in-memory`

Add a test under `reventless-in-memory/tests/components/readmodel/` (or similar) that:

1. Defines a tiny plugin with one StateChangeSlice (emits a DCB event) and one ReadModel.
2. The ReadModel uses a DCB-source mapping referencing the test plugin's DcbEventLog by name.
3. Dispatches a command through the slice, awaits the event flowing through the topic, asserts the projection state.
4. A second test variant uses a typo'd `sourceName` and asserts plugin assembly fails (covers Phase 2).

Reuse existing in-memory test fixtures (`DcbFixtures.res`, etc.).

### Phase 5 — Hybrid example

Extend `examples/online-shop-hybrid/` (or add a new one) with a multi-source ReadModel. Suggested shape:

- Source A: `Category` Aggregate event.
- Source B: `Product` StateChangeSlice DCB event (in the same plugin or a sibling DCB plugin's log).
- Target: a ReadModel that joins them — e.g., "products grouped by category" with category metadata from the Aggregate and product entries from the DCB slice.

The example doubles as integration regression: when CI runs the example app, the path is exercised end-to-end on the in-memory provider and (separately) the AWS provider.

### Phase 6 — Documentation

A short guide page (≤2 pages) covering:
- When to project DCB events into a ReadModel.
- The `name` convention (`<pluginName>DcbEventLog`).
- Typed-event subsetting (you only enumerate the variants you project).
- Multi-source layout: how to combine Aggregate and DCB sources in one `mappings` array.
- Failure modes: what happens if `name` is wrong, what to expect from CI now that Phase 2 lands.

---

## Design Context: Option A vs Option B

Two variants for cross-source ReadModel were considered:

- **Option A (this plan):** one runtime topic dict in `ReadModel_Builder.Make`, sources distinguished only by `name`. The plumbing is already partially in place; Plan 03 closes the developer-facing gap.
- **Option B:** a parallel `DcbMappings` module-type slot alongside the existing `Mappings`, threaded as a second functor argument: `ReadModel_Builder.MakeWithDcb(Spec, AggregateMappings, DcbMappings)`. Compile-time type-safe separation between Aggregate and DCB sources.

Option A is the recommended approach for both the immediate change and the long-term design. The case against Option B:

1. **It is not free at the application layer.** Every projection file splits — either two files (`FooProjections.res` + `FooDcbProjections.res`) or two modules within one file. Even a ReadModel that consumes only Aggregate events pays the bookkeeping (empty `DcbMappings` argument, file-discovery rules, generator pairing).
2. **The simple case pays a persistent cost.** A new contributor reading their first projection file must learn the DCB-vs-Aggregate distinction even when their first projection is Aggregate-only.
3. **It does not generalize.** A future third source category (external bus, federated topic, system metrics) requires another module-type slot and a global migration of every existing ReadModel. Option A absorbs new sources transparently.
4. **What the type safety actually buys is narrow.** Today's `Mapping.Make(Source, Target, ...)` already enforces `MappingImpl.sourceEvent := Source.event` — applying an Aggregate Source produces an Aggregate-typed `sourceEvent`, and the `project` function pattern-matches against that. The mismatch Option A would allow is a topic-name mismatch (subscribing to a DCB topic with Aggregate-shaped expectations). Phase 2's fail-fast plugin-assembly check converts that runtime decode failure into an even earlier assembly-time error — eliminating the class of mistake Option B was designed to catch, without any app-dev tax.
5. **The runtime cost of getting Option A wrong is small.** A misregistered source produces a decode error on the first event — visible in CI before any data flows. Phase 2 turns that into an explicit assembly-time error with a clear message. Option B's compile-time check is paying upfront for safety the runtime now offers cheaply.

Option B is **a contingency, not a successor.** Pursue it only if production traffic regularly produces silently-misrouted events that the integration-test layer doesn't catch — and only after Plan 03 has been in production long enough to provide that empirical signal.

A third variant — **Option C: bridge DCB events to a synthetic Aggregate `EventTopic` via Outbound→Inbound translation** — is rejected: it trades architectural clarity for operational complexity (extra Lambdas, extra queues, extra latency, semantic mismatch between events and commands).

---

## Verification

After Plan 03 lands:
- A ReadModel can declare a DCB-source mapping with no framework changes beyond the helper module.
- A typo'd `sourceName` fails plugin assembly with a clear error message — verified by Phase 4's negative test.
- The hybrid example runs green on in-memory and AWS providers.
- The guide page documents the pattern with both hand-rolled and helper-based forms.
- The Plan 03 audit note (Phase 1) is attached to the merge commit so future readers see the runtime trace.

---

## Effort Estimate

| Phase | Files affected (approx.) | Effort |
|-------|--------------------------|--------|
| 1. Audit and confirm plumbing | (read-only) | XS |
| 1.5. Align DCB meta.service | `DcbEventLog_Operations.res`, `DcbEventLog_Builder.res` + test | XS |
| 2. Source-name typo fail-fast | `Plugin_Builder.res` + tests | S |
| 3. `Projection.DcbSource` helper | `reventless-spec/src/types/Projection.res` | S |
| 4. End-to-end test | `reventless-in-memory/tests/` | S |
| 5. Hybrid example | `examples/online-shop-hybrid/` | M |
| 6. Documentation | one guide page | S |

**Total: S–M.** Most of the runtime work was done in earlier passes (the DCB topic merge, the `service`-name population). Plan 03 is mostly an audit + a developer-facing API + an example + tests + docs.

---

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Phase 1 audit reveals additional gaps in the runtime path. | If found, treat each as a separate phase with its own scope. The plan structure scales — most likely outcome is a smaller scope, not larger. |
| Developers misuse the `name` convention and the projection silently sees zero events. | Phase 2's fail-fast at plugin assembly. The same check protects Aggregate sources too — a side benefit. |
| Typed event-subset diverges from the DCB log's actual event set (slice adds a new variant; consumer projection silently ignores it). | Same behavior as today's Aggregate ReadModels (a new event variant is silently `Ignore`d). Document explicitly: a DCB-source projection covers the variants it knows about, no more. Adding awareness of new variants is a deliberate developer action. |
| The existing topic merge in `Plugin_Builder.res:246–252` was added speculatively and isn't actually exercised in any production code path. | Phase 1's audit verifies this. If the merge has gaps, Phase 1 expands scope. |
| Two ReadModels in different plugins want to subscribe to a third plugin's DcbEventLog. | Out of scope. Today's `allEventTopics` is per-plugin; cross-plugin DCB consumption is a separate question requiring a different topic-routing model. |

---

## Open Questions

1. **Does the framework auto-generate a `DcbSource` per plugin, or is hand-rolling the contract?** The Phase 3 helper makes hand-rolling cheap. An auto-generated module synthesizing the DCB log's full event union (from all slices in the plugin) is a possible Phase 7. Recommendation: skip for v1; let real usage decide whether full-union access is wanted.

2. **Where does the helper live?** `reventless-spec/src/types/Projection.res` is the natural home (the existing `Source` module type is already there). A separate `DcbSource.res` in the same package is also viable. Decide during Phase 3.

3. **Should typed event-subset declarations live with the source plugin or with each consumer?** Either. The plan recommends consumer-local declarations (each ReadModel owns the subset it cares about) so plugins remain decoupled. A shared "official" subset module per plugin is a possible future ergonomics improvement.

---

## Dependency Map

```
Plan 02 (Spec-First slice split) ──► Plan 03 (this plan) ──► Plan 04 (mixed-source AutomationSlice)
                                       │
                                       └──── shares topic-merge plumbing
```

Plan 03 has no hard dependency on Plan 02 — the slice file layout doesn't change which `EventTopic`s a `Mapping.Make` subscribes to. They can ship in either order. Plan 04 reuses Plan 03's typo fail-fast and Source-shape helper, so Plan 03 ships first within the source-routing track.

---

## Acceptance Criteria

- [x] Phase 1 audit note exists and confirms the runtime path. (`docs/analysis/done/mixed-source-readmodel-audit.md`)
- [x] Phase 1.5 fix: `meta.service` aligned with `allEventTopics` dict key (`DcbEventLog_Operations.serviceName` field).
- [x] `Projection.DcbSource.Make` helper exists and is exported.
- [x] A typo'd `sourceName` in any ReadModel `Mapping` fails plugin assembly (and any direct ReadModel construction) with a message naming the bad source.
- [x] A hybrid example app demonstrates one Aggregate source + one DCB source feeding the same ReadModel. (`examples/online-shop-hybrid/catalog/src/CatalogActivity/`)
- [x] The example app builds under in-memory.
- [x] At least one focused integration test in `reventless-in-memory/tests/` covers the DCB-source projection path end-to-end. (`DcbReadModelE2ETest.res`, `DcbReadModelTypoFailFastTest.res` — 4 tests, all pass.)
- [x] A guide page documents the convention, the helper, and the failure modes. (`docs/guides/mixed-source-readmodel.md`)
- [x] No regression in existing single-source Aggregate ReadModels (full monorepo + reventless-in-memory tests still build/pass).
