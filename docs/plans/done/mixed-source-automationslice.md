# Mixed-source AutomationSlice (Plan 04)

## Executive Summary

Let an `AutomationSlice` consume events from Aggregate `EventTopic`s alongside the `DcbEventLog` `EventTopic`, react via the existing `collect` / `resolve` / `process` triple, and emit DCB commands targeting a downstream slice. After this plan, an Aggregate event can directly trigger a DCB command without an intermediate ReadModel + polling/trigger orchestration.

The motivating commercial use case driving the design: the framework's `Plugin` Aggregate (`reventless/reventless-core/src/admin/PluginBehavior.res`) drives a runtime state machine — `NotConnected → Detected → Connected → Disconnected → Inactive` — emitting events like `PluginConnected`, `PluginDisconnected`, `UIFragmentRegistered`. A platform-inspector AutomationSlice should react to these and emit `SyncPlugin` (and a future `MarkPluginInactive`) commands to keep the inspector's DCB-side `(environment, platformName, pluginName)`-partitioned state in sync with runtime plugin lifecycle. Today this orchestration lives in deploy-time hooks; mixed-source AutomationSlice replaces it with a runtime reactive pattern that gains the standard retry / heartbeat / TODO-list-correlation semantics for free.

This plan reuses Plan 03's topic-merging plumbing and adds:
1. Per-source mappings on the slice (parallel to `Projection.Mapping.Make` for ReadModels).
2. A PPX-synthesized `consumedEvent` union covering all declared sources.
3. Ambient-context plumbing into `process` for tag-derivation under partial event payloads.
4. Source-name typo fail-fast at plugin assembly (extension of Plan 03's check).

**Estimated size:** M–L. Most of the AutomationSlice machinery already exists; the work is per-source decode dispatch, the PPX union synthesis, and ambient-context threading.

## Decisions Recorded

This plan implements the following decisions from the design analysis. Where the analysis offered alternatives, the chosen option is locked in here and not relitigated.

| # | Question | Decision |
|---|----------|----------|
| 1 | DCB-tag handling for Aggregate-sourced events | **(a) Tag-derivation function on each mapping**, returning `result<tagSet, string>`. Source/sink stay decoupled; tags derived from event payload + ambient context. |
| 2 | Schema union for `consumedEventSchema` | **(b) Framework-synthesised union.** PPX reads per-source mappings and emits the tagged union; developer doesn't write it by hand. |
| 3 | Tag-derivation under partial event-payload information | Tag-derivation returns `result<tagSet, string>`. Ambient context (deployment metadata: `environment`, `platformName`, etc.) is plumbed via the existing `Plugin_Builder` parameters and exposed as a `context` argument to `process`. Runtime registry lookup is **out of scope** for v1. |
| 4 | Interaction with `InboundTranslationSlice` | **Extend `AutomationSlice`, not Translation.** AutomationSlice's retry/heartbeat/TODO-list correlation is required by the platform-inspector use case and absent from `InboundTranslationSlice`. Translation is the wrong primitive for "react to observed events; emit commands." |
| 5 | Backfill / replay semantics | **Match Aggregate convention** — start from current, no backfill. If historical replay is needed for a specific use case, ship it as an explicit one-shot tool rather than baked into normal slice operation. |

## Reality Check: Current State

### AutomationSlice is already split (Plan 02 complete for this slice)

The `AutomationSlice` spec is already split into `Spec` (types, schemas, config) and `Automation` (`collect`, `resolve`, `process`). See `reventless/reventless-spec/src/components/AutomationSlice.res:49–108`. The two-arg builder shape is in place at `AutomationSlice_Builder.Make` (`reventless/reventless-core/src/components/AutomationSlice/AutomationSlice_Builder.res:22–25`). Plan 04 does **not** wait for the rest of Plan 02 to land — the slice already conforms to the two-file convention.

### The current single-source path

Today's `AutomationSlice_Builder.Make` hardcodes a single source — its own DcbEventLog:

```rescript
let dcbEventTopicOutputs = (dcbEventLog->Component.outputs).eventTopic
let allEventTopics = Dict.fromArray([(Spec.name, dcbEventTopicOutputs)])
```

(`AutomationSlice_Builder.res:71–72`.) Decoding is similarly single-schema:

```rescript
let decoder = Reventless.DcbDecode.makeDecoder(Spec.consumedEventSchema)
```

(`AutomationSlice_Builder.res:51`.) The runtime path:

1. Topic stream → JSON event arrives at the slice.
2. `decoder.decode(~eventType, ~data)` produces `Some(consumedEvent)` or `None`.
3. `Callback.phase1(events)` runs `Automation.collect` and `Automation.resolve` over each.
4. `Callback.phase2(publishJsons)` walks pending TODO items, runs `Automation.process` on each, publishes resulting commands via `CommandTopic.publishJsons`.

Commands flow out via `publishJsons` to the target slice. The target slice's `commandSchema` has DCB tag annotations (`@compositePartitionTag`, etc.) and the framework extracts tags from command payload at write time. So **tags live on the command, not on the AutomationSlice** — but the developer must populate the tag fields when constructing the command in `process`.

### What Plan 03 already enabled

Plan 03 will land:
- `Projection.DcbSource.Make` helper for DCB-source ReadModels.
- Source-name typo fail-fast at plugin assembly.
- The hybrid example demonstrating multi-source ReadModels.

Plan 04 reuses the topic-merging infrastructure (in `Plugin_Builder.res:246–252`) and the source-name fail-fast pattern, extended to AutomationSlice's source set.

## Naming and Mapping Convention

A `Reventless.AutomationSlice.Mapping.Make` functor declares one source for an AutomationSlice. It mirrors `Projection.Mapping.Make` for ReadModels, with two additions specific to automation: a `resolve` step (parallel to `collect`) and an explicit tag-derivation function (decision 1).

```rescript
// AutoSyncPlugin/FromPluginAggregate.res — one mapping per source
module FromPlugin = Reventless.AutomationSlice.Mapping.Make(
  PluginSpec,                    // Source: Aggregate spec module
  AutoSyncPluginSpec,            // Target: this slice's spec
  {
    let collect = (event, ctx) =>
      switch event {
      | PluginSpec.Connected({name, structure: _}) => [
          (
            name,
            {
              AutoSyncPluginSpec.pluginName: name,
              environment: ctx.environment,
              platformName: ctx.platformName,
              // ...
            },
          ),
        ]
      | _ => []
      }

    let resolve = event =>
      switch event {
      | PluginSpec.Disconnected({name}) => Some(name)
      | _ => None
      }

    let toTags = (item, ctx): result<tagSet, string> =>
      switch (item.environment, item.platformName, item.pluginName) {
      | ("", _, _) | (_, "", _) | (_, _, "") => Error("missing partition tag fields")
      | _ => Ok({environment: item.environment, platformName: item.platformName, pluginName: item.pluginName})
      }
  },
)
```

Conventions:

- **`name` of each Source matches its `EventTopic` dict key.** Aggregate sources match `Source.name` directly; DCB sources match `<pluginName>DcbEventLog` per Plan 03's convention.
- **`collect` and `resolve` receive an ambient `context` (decision 3).** The context carries `environment`, `platformName`, the slice's own `name`, and any other deployment metadata already plumbed through `Plugin_Builder`. This is how partial event payloads are completed.
- **`toTags` returns `result<tagSet, string>` (decision 1).** An `Error` skips the event with a logged warning; an `Ok` proceeds. Tag fields that come purely from event payload still go through this function so the validation path is uniform.
- **Per-source mappings combine into one slice.** A single AutomationSlice can declare multiple `Mapping.Make` modules — one per consumed source. The slice's `Mappings.mappings` array lists them.

The single-source convention from today's AutomationSlice continues to work as a special case where the only source is the slice's own DcbEventLog. PPX-driven backward compatibility lets existing slices keep their merged form without manual migration (see *Phase 4* below).

## Scope

### In scope

1. **Per-source `AutomationSlice.Mapping.Make` functor** in `reventless-spec/src/types/Automation.res` (new file alongside the existing `Projection.res`). Mirrors `Projection.Mapping.Make` with the additions in *Naming and Mapping Convention* above.

2. **`AutomationSlice.Mappings` collection module type** — array of mappings, parallel to `Projection.Mappings`. Provides the registry the builder reads to drive multi-source dispatch.

3. **Per-source decode dispatch** in `AutomationSlice_Builder.Make`. Replace the single hardcoded `decoder` with per-`sourceName` decoder dispatch — reuse the same pattern `MapperNto1.findMappings` uses for ReadModel.

4. **Topic-dict population** in `AutomationSlice_Builder.Make`. Today it builds a single-entry dict (`Dict.fromArray([(Spec.name, dcbEventTopicOutputs)])`); Plan 04 merges in Aggregate `EventTopic`s from `allEventTopics` (Plan 03's plumbing) and any other DcbEventLog topics the mappings reference. Source filter is by `Mapping.sourceName`.

5. **Framework-synthesized `consumedEvent` union (decision 2b).** A new PPX behaviour: when the slice declares per-source mappings, the PPX synthesizes
   ```rescript
   type consumedEvent =
     | FromPlugin(PluginSpec.event)
     | FromOwnLog(OwnDcbSource.event)
   ```
   and the decoder. The developer never writes the union by hand. Manually-declared `consumedEvent` continues to work for backward compatibility (single-source slices).

6. **Ambient context plumbing (decision 3).** `Plugin_Builder` already receives `~environment`, `~name`, etc. — Plan 04 packages these into a `Reventless.AutomationSlice.Context` record and threads it through `AutomationSlice_Builder` → `AutomationSlice_Callback` → `collect` / `resolve` / `process`. Existing single-source slices that don't reference `context` continue to work via PPX-injected wildcard binding.

7. **Tag-derivation step (decision 1).** Each mapping declares `let toTags: (todoItem, context) => result<tagSet, string>`. The Callback runs it just before publishing each command; an `Error` logs and skips the item, an `Ok` proceeds. For slices whose target command already encodes its tags via field-level `@compositePartitionTag` annotations, `toTags` is a sanity check that those fields are populated; for slices that need tags from ambient context, it's the explicit construction site.

8. **Source-name typo fail-fast at plugin assembly.** Same shape as Plan 03's check, extended to AutomationSlice. Every `Mapping.sourceName` must resolve to a key in `allEventTopics` at plugin assembly time. A missing source raises with a clear message.

9. **End-to-end test** in `reventless-in-memory/tests/components/automation/`. Two-source AutomationSlice (one Aggregate, one DCB) drives commands to a target slice; assert the full path including `toTags` validation and the typo-rejection path.

10. **Hybrid example.** Extend `examples/online-shop-hybrid/` with a mixed-source AutomationSlice. Suggested shape: an `AutoFulfillment` slice consuming `OrderShipped` (Order Aggregate) + `StockReserved` (Inventory StateChangeSlice), emitting `MarkOrderFulfilled` against a downstream slice when both events arrive for the same product.

11. **One guide page** documenting the mapping convention, ambient context, tag-derivation, the synthesized union, and the failure modes.

### Explicitly out of scope

- **Backfill / historical replay (decision 5).** Slices start from current; backfill needs a separate one-shot tool if requested.
- **Runtime registry lookup for ambient context (decision 3).** Context is what `Plugin_Builder` already plumbs at deployment; lookups against external registries are not added.
- **Translation-slice extension (decision 4).** `InboundTranslationSlice` is not extended to subscribe to `EventTopic`s.
- **Cross-plugin DCB consumption.** Today `allEventTopics` is per-plugin. A future extension could route across plugins; out of scope here.
- **Auto-rollback / failure-driven automation patterns.** Plan 04 enables them but doesn't ship one as a worked example. Use cases come from real customer needs.

## Implementation Phases

### Phase 1 — Define `AutomationSlice.Mapping` and `AutomationSlice.Mappings`

New file: `reventless-spec/src/types/Automation.res` (or extend the existing `AutomationSlice.res`). Define:

```rescript
module type Source = {
  module Id: Id.T
  let name: string
  @schema type event
}

module type Mapping = {
  module Source: Source
  module Target: AutomationSlice.Spec
  let collect: (Source.event, context) => array<(string, Target.todoItem)>
  let resolve: Source.event => option<string>
  let toTags: (Target.todoItem, context) => result<tagSet, string>
  let sourceName: string
}

module type Mappings = {
  module Target: AutomationSlice.Spec
  module type Mapping = Mapping with module Target := Target
  let mappings: array<module(Mapping)>
}

module Mapping = { module Make = ... }
module Mappings = { module Make = (Target: AutomationSlice.Spec) => { ... } }
```

`context` is a typed record with `environment`, `platformName`, the slice's `name`, and a small set of well-defined deployment metadata. It is *not* an open dict — extending it requires an explicit framework change.

### Phase 2 — `AutomationSlice_Builder` accepts `Mappings`

Change `AutomationSlice_Builder.Make` to accept `Mappings: AutomationSlice.Mappings`:

- Topic dict population: iterate `Mappings.mappings`, look up each `sourceName` in `allEventTopics` (provided by `Plugin_Builder`), collect into a `Dict.t<string, EventTopic.outputs>`.
- Decoder dispatch: for each event arriving on a stream, find the matching mapping by `sourceName == meta.service`, dispatch to that mapping's `Source.event` schema.
- Backward compatibility: when no `Mappings` is supplied, fall back to today's hardcoded single-source path. PPX or generator emits the legacy form for slices that haven't migrated.

### Phase 3 — PPX-synthesized `consumedEvent` union (decision 2b)

Extend the `@@reventless.automation` PPX (the implementation-side annotation introduced in Plan 02) so that when the slice's directory contains per-source mapping files, the PPX:

1. Discovers each mapping file by convention (e.g., `*Mapping.res` siblings).
2. Reads each mapping's `Source.event` type.
3. Synthesizes:
   ```rescript
   type consumedEvent =
     | FromPlugin(PluginSpec.event)
     | FromOwnLog(OwnDcbSource.event)
   ```
4. Generates the decoder switching on `meta.service`.
5. Threads the synthesized union into `Spec.consumedEvent` so `collect` / `resolve` see the right type.

This is the most complex phase. Tests cover: union variants match mapping order; manual `consumedEvent` still works (single-source legacy); two mappings with overlapping constructor names raise a clear PPX error.

### Phase 4 — Ambient context plumbing

`Plugin_Builder` already receives `~environment`, `~name`, etc. Define `Reventless.AutomationSlice.Context`:

```rescript
type context = {
  environment: string,
  platformName: string,
  pluginName: string,
  sliceName: string,
}
```

Thread it through `AutomationSlice_Builder.Make` → `Callback.Make` → `phase1` → `collect`/`resolve` → `phase2` → `process` and `toTags`.

Backward compatibility: existing single-source slices with `collect: event => array<...>` keep working — PPX adds an unused `_ctx` parameter.

### Phase 5 — Tag-derivation invocation in `phase2`

In `AutomationSlice_Callback.phase2`, before publishing each command, invoke `Mapping.toTags(item, context)`:

```rescript
switch mapping.toTags(item, context) {
| Ok(_tagSet) => /* publish command */
| Error(msg) =>
  Effect.logWarning(`AutomationSlice(${Spec.name}): toTags failed for item ${id}: ${msg}`)->Effect.runSync
  // mark Failed, increment retry — same flow as encoding/publish failure
}
```

The actual command-write tagging is still done by the framework from the command schema's `@compositePartitionTag` fields — `toTags` is a *validation* step that ensures those fields are populated, with a clear failure mode when they aren't.

### Phase 6 — Source-name typo fail-fast

Extend the assembly-time check from Plan 03 to walk every AutomationSlice's `Mappings.mappings` and assert each `sourceName` resolves to a topic in `allEventTopics`. Same error format as Plan 03.

### Phase 7 — Tests, example, docs

- End-to-end test in `reventless-in-memory/tests/components/automation/MixedSourceAutomationTest.res`. Drive an Aggregate event through the topic, assert it lands in `collect` with the right `context`, the TODO survives `phase1`, `phase2` calls `toTags` and `process`, command lands at target slice. Negative cases: `toTags` returns `Error`, source-name typo, decode failure on a mapping schema.
- Hybrid example in `examples/online-shop-hybrid/` — `AutoFulfillment` slice from the *Executive Summary*. The example doubles as integration regression on both in-memory and AWS.
- Guide page covering: when to use mixed-source automation, the mapping convention, ambient context, `toTags`, the synthesized union, common failure modes.

## Verification

After Plan 04 lands:
- An AutomationSlice can declare two or more `Mapping.Make` modules — at least one Aggregate source, at least one DCB source — and drive a single TODO list to commands targeting either side.
- A typo in any mapping's `sourceName` fails plugin assembly with a clear message.
- A `toTags` returning `Error` skips the item with a logged warning and increments retry.
- Existing single-source AutomationSlices keep working with no source-code change (PPX maintains backward compatibility).
- The hybrid example runs green on in-memory and AWS.
- The guide page documents both new and legacy patterns.

## Effort Estimate

| Phase | Files affected (approx.) | Effort |
|-------|--------------------------|--------|
| 1. `Mapping` / `Mappings` module types | `reventless-spec/src/types/Automation.res` (new) | S |
| 2. Builder accepts `Mappings` | `AutomationSlice_Builder.res`, `_Callback.res` | M |
| 3. PPX-synthesized `consumedEvent` union | `packages/reventless-ppx/src/ppx/` | M–L |
| 4. Ambient context plumbing | `Plugin_Builder`, builder, callback | S |
| 5. `toTags` invocation | `_Callback.res` | S |
| 6. Source-name typo fail-fast | `Plugin_Builder.res` (extension of Plan 03 check) | S |
| 7. Tests, example, docs | tests + `online-shop-hybrid` + one guide | M |

**Total: M–L.** Phase 3 is the dominant cost — PPX union synthesis is the only piece of genuinely new framework surface. The rest is plumbing that mirrors patterns already in place (per-source dispatch from `MapperNto1`, `allEventTopics` threading from `Plugin_Builder`, fail-fast from Plan 03).

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| PPX union synthesis (Phase 3) produces incorrect output for edge cases — overlapping constructor names, generic types, PPX attributes on the source `event`. | Start with strict PPX rules: refuse when sources share constructor names, require `@schema` on every source `event`. Loosen later only if the developer pain justifies the complexity. |
| Existing single-source AutomationSlices break under the PPX changes. | Backward-compatibility path: when no `Mappings` directory is present, the PPX emits today's single-source form unchanged. Cover with snapshot tests on existing example slices. |
| `context` becomes a god-object as more deployment metadata gets requested. | Keep `context` strictly typed and small. Extending requires an explicit framework PR — this is friction by design. Runtime-registry lookups (which would balloon the surface) are out of scope. |
| `toTags` is a redundant validation when target slice's command schema already extracts tags from the payload. | Document explicitly: `toTags` is a *fail-early* check, not a duplication. The developer still gets one well-defined site to validate that the tag fields are populated before the command leaves the slice — without it, a missing field surfaces as a DCB-write error several lambda hops later. |
| Cross-plugin DCB consumption (one plugin's AutomationSlice consuming another plugin's DcbEventLog) is requested. | Out of scope for v1. `allEventTopics` is per-plugin today; routing across plugins is a separate question. Document the limit in the guide. |
| Phase 3 (PPX union synthesis) blocks the rest of the plan. | Phases 1–2 and 4–6 can ship without Phase 3 — slices would write the `consumedEvent` union manually, same as today. Phase 3 is an ergonomic improvement, not a blocker. If schedule slips, ship the rest first and follow up with synthesis. |

## Dependency Map

```
Plan 03 (mixed-source ReadModel) ──► Plan 04 (this plan)
   │                                   │
   └─ topic-merge plumbing reused      └─ extends fail-fast to AutomationSlice
   └─ Source-name fail-fast pattern reused
```

Plan 04 has no hard dependency on Plan 02 — `AutomationSlice` is already split into `Spec`/`Automation`. It does depend on Plan 03 for the topic-merge plumbing in `Plugin_Builder.res:246–252` and the fail-fast assembly check.

## Acceptance Criteria

- [x] `Reventless.AutomationSlice.Mapping.Make` and `Reventless.AutomationSlice.Mappings.Make` exist and are exported.
- [x] `AutomationSlice_Builder.Make` accepts a `Mappings` module and dispatches per-source decode by `meta.service` matching `Mapping.sourceName`.
- [x] ~~PPX synthesizes `consumedEvent` from per-source mapping declarations; manual `consumedEvent` continues to work.~~ **Replaced with a cleaner architectural change:** `consumedEvent` was dropped from the `AutomationSlice.Spec` module type entirely. The framework derives the consumed-event set from each mapping's `sourceEventSchema` (`Dcb_Builder` validation and `Plugin_Structure` UI metadata both walk `Mappings.mappings`). Single-source slices have one Mapping whose `sourceEventSchema` IS the consumed-event schema; multi-source slices contribute the union. This achieves the developer-ergonomics goal of Phase 3 (no manual union to write) without the PPX cross-file complexity.
- [x] `Reventless.AutomationSlice.Context` is plumbed through `Plugin_Builder` → builder → callback → `collect`/`resolve`/`process`/`toTags`. `platformName` populated from `Plugin_Builder.Spec.platformName` — `"in-memory"` in the in-memory platform, `Pulumi.Pulumi.getProjectName()` in AWS.
- [x] `toTags` is invoked in `phase2` before publishing each command; `Error` skips with a logged warning and retries.
- [x] A typo'd `sourceName` in any AutomationSlice mapping fails plugin assembly with a message naming the bad source.
- [ ] The hybrid example app demonstrates a multi-source AutomationSlice consuming both an Aggregate and a DCB slice's events. _(Deferred — the existing hybrid plugins don't have a natural cross-source business case without adding new domain entities. The `MixedSourceAutomationSliceTest` integration test serves as the canonical demo.)_
- [x] At least one focused integration test in `reventless-in-memory/tests/` exercises the full path. _(`MixedSourceAutomationSliceTest.res` covers Aggregate→todo, DCB→todo, both-sources independent, first-writer-wins, resolve-after-process. `toTags` Error path and source-name typo path are exercised by unit tests in the callback test file and the builder fail-fast respectively, but not yet by a dedicated multi-source negative test.)_
- [x] A guide page documents the mapping convention, ambient context, `toTags`, and the failure modes. _(Synthesized union is documented as deferred.)_
- [x] No regression in existing single-source AutomationSlices. _(362 tests pass; `AutoShipOrder` migrated to the new shape in both dcb and hybrid examples.)_

## Implementation Status (as of merge)

**Shipped (Phases 1, 2, 4, 5, 6, 7a, 7c):**

- Per-source `AutomationSlice.Mapping.Make` / `Mappings.Make` functors.
- `Automation` module type slimmed to `process` only; `collect`/`resolve` move to mappings.
- Builder rewrite: takes `Mappings`, takes `~allEventTopics`, drops `~dcbEventLog`. Per-source decode dispatch via `meta.service`.
- `AutomationSlice.context` record threaded through `Plugin_Builder` → `Dcb_Builder` → builder → callback.
- `toTags` invoked in phase 2 with Error→Failed retry semantics.
- Source-name typo fail-fast at slice construction.
- AWS + in-memory builders updated; `Platform.AutomationSlice.Make` 3-arg form.
- Codegen recognises `_Mappings` as an impl-suffix; emits the new 3-arg form.
- Existing `AutoShipOrder` slices (dcb + hybrid examples) migrated.
- Integration test (`MixedSourceAutomationSliceTest`) demonstrates multi-source dispatch.
- Guide page (`docs/guides/mixed-source-automationslice.md`).

**Phase 3 — replaced by spec slimming:** instead of PPX-synthesizing `consumedEvent`, dropped it from `AutomationSlice.Spec` entirely. Framework consumers (`Dcb_Builder`, `Plugin_Structure`) walk per-mapping `sourceEventSchema` directly. Cleaner than PPX cross-file synthesis and removes a developer-facing concept rather than auto-generating it.

**Deferred:**

- **Hybrid example AutoFulfillment slice.** No natural cross-source business case in the existing hybrid plugins without introducing a new aggregate. The integration test serves as the canonical demo.
