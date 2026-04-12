# Analysis: AWS Runtime Builder Review

**Date**: 2026-04-13  
**Scope**: All 15 files in `reventless-aws/src/adapter/Runtime/`

---

## Part 1 — Aggregate Builders (6 files)

`AggregateRuntime_Builder_Single`, `_PerAggregate`, `_Micro` and their `_Async` clones.

### Finding A1 — Comment drift in Single_Async (trivial)

`AggregateRuntime_Builder_Single_Async` is missing two comment blocks present in the sync version:
- `// Extract the SQS queue from the channel parts` in `forCommandTopic`
- Section comments in `finish()`: `// Build HANDLER_CONFIG as a single JSON env var…`, `// Build AssetArchive: static re-export + user packages`

**Impact**: None. Readability only.

### Finding A2 — Memory/timeout isolation asymmetry (design question)

`Single` and `PerAggregate` use one shared `memorySize`/`timeout` field for all components. `Micro` correctly separates these per Lambda:

```rescript
// Single / PerAggregate — all components share one field:
memorySize: int,
timeout: int,

// Micro — per-function fields:
commandTopicMemorySize: int,    commandTopicTimeout: int,
commandGeneratorMemorySize: int, commandGeneratorTimeout: int,
eventCollectorMemorySize: int,  eventCollectorTimeout: int,
```

In `Single`/`PerAggregate`, `Math.Int.max` prevents any component from lowering the setting, so the effective memory is the maximum across all `for*` calls. This is correct for `Single` (one Lambda for all aggregates) but less clear for `PerAggregate` (one Lambda per aggregate but still one Lambda per aggregate — CommandTopic and EventCollector share it). The behavior is sound but undocumented.

**Decision needed**: confirm that `PerAggregate` intentionally collocates CommandTopic and EventCollector in one Lambda.

### Finding A3 — Copy-paste across all 6 files (refactor opportunity)

`registerAggregate`, `getStoredSpec`, `forCommandGenerator` body, and the archive-building pattern each appear verbatim 6 times. Any fix must be applied 6 times. Candidate for a shared `AggregateRuntime_Helpers` module.

### Finding A4 — Error message strings (no issue)

All six files follow a consistent labelling convention: `single`, `single-async`, `per-aggregate`, `per-aggregate-async`, `micro`, `micro-async`. No inconsistencies.

---

## Part 2 — Non-Aggregate Builders (9 files)

### Overview

| File | Pattern | Purpose |
|---|---|---|
| `EventCollectorRuntime_Builder_Single` | deferred single Lambda | All read-model EventCollectors → `"AllReadModels"` Lambda |
| `EventCollectorRuntime_Builder_PerEventCollector` | immediate per-instance Lambda | One Lambda per EventCollector |
| `AutomationSliceRuntime_Builder_Single` | deferred single Lambda | All AutomationSlices → one Lambda |
| `StateViewSliceRuntime_Builder_Single` | deferred single Lambda + DCB variant | Two finish paths: streaming and DCB |
| `SideEffectHandlerRuntime_Builder_Single` | deferred single Lambda | All SideEffectHandlers → one Lambda |
| `TaskRuntime_Builder_PerBucket` | immediate per-bucket Lambda | One Lambda per Task bucket |
| `PluginRuntime_Builder` | functor `Make` | Admin plugin: EventCollector, Heartbeat, DCB CommandTopic |
| `PluginExtensionPointRuntime_Builder` | immediate, no finish | Platform EP command topic Lambda |
| `ExtensionPointRuntime_Builder_PerExtensionPoint` | immediate, no finish | One Lambda per EP command topic |

### Finding B1 — `StateViewSliceRuntime_Builder_Single.finish()` hardcodes memory/timeout (correctness bug)

`finish()` computes `maxMemorySize` and `maxTimeout` by reducing over stored specs, then ignores them:

```rescript
// Lines ~200–205 — correct computation:
let (maxMemorySize, maxTimeout) = specs->Array.reduce((0, 0), ...)

// Lines ~265–270 — hardcoded, ignores the computed values:
let runtime = RuntimeEnvironment_Lambda.makeFromCodeAsset(
  ~name="AllStateViewSlices",
  ~memorySize=1024,   // ← should be maxMemorySize
  ~timeout=30,        // ← should be maxTimeout
  ...
)
```

Every other Single builder (`EventCollector`, `Automation`, `SideEffect`) correctly passes `~memorySize=maxMemorySize, ~timeout=maxTimeout`. The `StateViewSlice` Lambda will always be provisioned with 1024 MB / 30 s regardless of what callers requested.

**Fix**: replace `~memorySize=1024, ~timeout=30` with `~memorySize=maxMemorySize, ~timeout=maxTimeout` in `finish()`.

### Finding B2 — `AutomationSliceRuntime_Builder_Single` wrong error label (minor bug)

`forEventCollector` error message says `"(bundled)"` — a copy-paste from `PerEventCollector`:

```rescript
// AutomationSliceRuntime_Builder_Single line ~90 (wrong):
`forEventCollector(bundled): eventCollector ${name} has no parent`

// Should match every other Single builder:
`forEventCollector(single): eventCollector ${name} has no parent`
```

**Fix**: change `"(bundled)"` to `"(single)"`.

### Finding B3 — `PluginExtensionPointRuntime_Builder` and `ExtensionPointRuntime_Builder_PerExtensionPoint` missing `finish` (interface gap)

Every other builder exports `let finish = () => ()` or a real implementation. These two files have no `finish` binding at all. Any caller that iterates builders and calls `finish()` will hit a type error or runtime crash.

**Fix**: add `let finish = () => ()` to both files.

### Finding B4 — `publishToAggregates` env var prefix inconsistency (potential runtime bug)

Two different prefixes are used for the same logical concept (routing queue URLs to aggregates):

```rescript
// TaskRuntime_Builder_PerBucket:
let envVar = `PUBLISH_${aggName}_QUEUE_URL`

// PluginExtensionPointRuntime_Builder + ExtensionPointRuntime_Builder_PerExtensionPoint:
let envVar = `PTA_${aggName}_QUEUE_URL`
```

The runtime entry points must read the correct prefix. If `TaskRuntime_Builder_PerBucket` Lambda reads `PTA_` or the EP Lambdas read `PUBLISH_`, routing silently fails.

**Verify**: confirm the entry points (`TaskEntryPoint.mjs`, `PluginExtensionPointEntryPoint.mjs`, `ExtensionPointEntryPoint.mjs`) each read the correct prefix, and document why they differ (or unify them).

### Finding B5 — `StateViewSliceRuntime_Builder_Single` partially extracted `buildLambda` but `finish()` duplicates it anyway (maintainability)

`buildLambda` (lines ~94–141) was added to factor out archive construction, but `finish()` does not call it — it repeats the full block again with the hardcoded defaults described in B1. This also means `buildLambda` and the inline `finish()` block can diverge independently.

**Fix**: make `finish()` call `buildLambda` (after fixing B1).

### Finding B6 — `outputOrPlaceholder` helper duplicated (trivial)

`PluginExtensionPointRuntime_Builder` and `PluginRuntime_Builder.Make` each define a local `outputOrPlaceholder` helper with identical implementation. Not shared.

### Finding B7 — `PluginRuntime_Builder` is a functor; all others are plain modules (undocumented asymmetry)

`PluginRuntime_Builder` uses `module Make = (EventCollectorChannel: ...) => { ... }` to inject the event collector channel, while all other builders hardcode `module EventCollectorChannel = EventCollectorChannel.DynamoDbStream`. No comment explains why this one requires injection. It may be that the admin plugin needs a different channel in some deployment, but this is not documented.

### Finding B8 — Copy-paste across all builders (same as A3, but wider scope)

The archive-building block (~15 lines) appears in every builder that creates a Lambda — at least 8 files total. `StateViewSliceRuntime_Builder_Single` partially extracted it but did not follow through. The `handlerConfigOutput` / `envVars` assembly pattern is duplicated across all four Single builders.

---

## Priority Summary

| # | Finding | Severity | Fix effort |
|---|---|---|---|
| B1 | StateViewSlice `finish()` ignores computed memory/timeout | Correctness bug | Trivial |
| B2 | AutomationSlice error label says "(bundled)" | Minor bug | Trivial |
| B3 | PluginExtensionPoint + ExtensionPoint missing `finish` | Interface gap | Trivial |
| B4 | `PUBLISH_` vs `PTA_` env var prefix inconsistency | Potential runtime bug | Verify first |
| B5 | StateViewSlice `buildLambda` not used in `finish()` | Maintainability | Small |
| A2 | PerAggregate memory/timeout colocation undocumented | Design question | Document only |
| A1 | Single_Async missing comments | Trivial | Trivial |
| B6 | `outputOrPlaceholder` duplicated | Trivial | Trivial |
| A3/B8 | Archive-building copy-pasted across 14 files | Refactor opportunity | Large |
