# Bundled Terminology Cleanup

## Problem

The word "Bundled" appears extensively in code, comments, and file names as a legacy artifact from the migration away from Pulumi's `CallbackFunction` approach to the current code-asset approach (esbuild + Lambda code upload). Since all Lambda handlers are now deployed this way, "Bundled" often conveys no useful information and confuses readers who expect it to mean something distinctive.

## Root Cause

During the migration, three AWS-specific builder files were created with `_Bundled` suffix to distinguish them from the original CallbackFunction-based builders:
- `StateViewSlice_Builder_Bundled.res`
- `AutomationSlice_Builder_Bundled.res`
- `OutboundTranslationSlice_Builder_Bundled.res`

`Platform.res` exposed these as `.Bundled` sub-modules, and plugin files added `(BUNDLED)` comment labels throughout.

## What NOT to change

- File names like `BundledAggregateHandlerFactory.mjs` — runtime factory files inside the Lambda layer. Renaming them requires updating all `specModulePath` references generated at deploy time. Leave for a dedicated layer-refactor plan.
- `docs/plans/done/bundled-lambda-handlers.md` — historical implementation record, accurate as written.
- `RuntimeEnvironment_Lambda.res` `make` function — retained for module type compatibility; tracked separately.
- AppSync comments mentioning "bundled JS code" — these refer to esbuild output for AppSync resolvers (a general programming term), not the Reventless-specific concept.

---

## Phase 1 — Remove `(BUNDLED)` comment labels ✅ DONE

Removed `(BUNDLED)` section labels from `CatalogPlugin_Aws.res` and `OrderingPlugin_Aws.res`.

## Phase 2 — Deduplicate StateViewSlice builders ✅ DONE

- Deleted `StateViewSlice_Builder_Bundled.res` (was identical to base)
- Migrated callers from `Platform.StateViewSlice.Bundled.Make` to `Platform.StateViewSlice.Make`
- Removed `module Bundled` from Platform.res StateViewSlice block

## Phase 3 — Merge AutomationSlice / OutboundTranslationSlice bundled builders ✅ DONE

- Rewrote `AutomationSlice_Builder.res` to include `registerAutomationSlice` (previously only in `_Bundled`)
- Rewrote `OutboundTranslationSlice_Builder.res` similarly
- Deleted `AutomationSlice_Builder_Bundled.res` and `OutboundTranslationSlice_Builder_Bundled.res`
- Removed `module Bundled` from Platform.res for both slice types
- Removed `module Bundled` aliases from in-memory Platform.res
- Removed `module Bundled` requirement from `Platform.T` in reventless-infra
- Migrated callers in `OrderingPlugin_Aws.res` to `Make`

---

## Phase 4 — Fix example `Main.res` file headers

**Files:**
- `examples/online-shop-hybrid/catalog-aws/src/Main.res` lines 1-3:
  - Remove "bundled variant" / "bundled Lambda handlers"
  - Fix stale "DCB slices use standard CallbackFunction handlers" (wrong — they use code-asset handlers)
- `examples/online-shop-hybrid/ordering-aws/src/Main.res` line 1:
  - Remove "bundled variant"

## Phase 5 — Fix `Platform.res` comments

Seven comments in `reventless/reventless-aws/src/Platform.res` still reference "bundled":

| Line | Current | Replacement |
|------|---------|-------------|
| 14 | "bundled slice builders" | "slice builders" |
| 116 | "bundled DCB slice builders" | "DCB slice builders" |
| 131 | "Non-bundled Make satisfies Platform.T but registers no entry point." | "This Make satisfies Platform.T but registers no Lambda entry point." |
| 487 | "bundled DCB CommandTopic handler" | "DCB CommandTopic Lambda handler" |
| 499 | "bundled slice builders" | "slice builders" |
| 508 | "bundled slice Lambdas" | "slice Lambdas" |
| 514 | "bundled heartbeat handler" | "heartbeat Lambda handler" |

## Phase 6 — Rename `bundledXxxInfo` types and variables in runtime builders

Across 13 files in `reventless/reventless-aws/src/adapter/Runtime/`, every file defines a `bundledXxxInfo` type and `bundledXxxInfos` dict. Drop the `bundled` prefix — within each file it is the only kind of info tracked.

| File | Current | New |
|------|---------|-----|
| `AggregateRuntime_Builder_Single.res` | `bundledAggregateInfo` / `bundledAggregateInfos` | `aggregateInfo` / `aggregateInfos` |
| `AggregateRuntime_Builder_PerAggregate.res` | same | same |
| `AggregateRuntime_Builder_Micro.res` | same | same |
| `EventCollectorRuntime_Builder_Single.res` | `bundledReadModelInfo` / `bundledReadModelInfos` | `readModelInfo` / `readModelInfos` |
| `EventCollectorRuntime_Builder_PerEventCollector.res` | same | same |
| `StateViewSliceRuntime_Builder_Single.res` | `bundledStateViewSliceInfo` / `bundledInfos` | `sliceInfo` / `sliceInfos` |
| `AutomationSliceRuntime_Builder_Single.res` | `bundledAutomationSliceInfo` | `sliceInfo` |
| `SideEffectHandlerRuntime_Builder_Single.res` | `bundledSideEffectInfo` / `bundledSideEffectInfos` | `sideEffectInfo` / `sideEffectInfos` |
| `TaskRuntime_Builder_PerBucket.res` | `bundledTaskBucketInfo` / `bundledTaskBucketInfos` | `taskBucketInfo` / `taskBucketInfos` |
| `ExtensionPointRuntime_Builder_PerExtensionPoint.res` | `bundledExtensionPointInfo` / `bundledInfos` | `extensionPointInfo` / `extensionPointInfos` |
| `PluginExtensionPointRuntime_Builder.res` | `bundledPluginEPInfo` / `bundledInfo` | `pluginEPInfo` / `info` |
| `PluginRuntime_Builder.res` | `bundledAdminConfig` / `bundledDcbConfig` / `bundledHeartbeatConfig` | `adminConfig` / `dcbConfig` / `heartbeatConfig` |
| `CounterHandler_DynamoDbStream.res` | `bundledCounterInfo` | `counterInfo` |

## Phase 7 — Fix error message strings in runtime builders

Runtime builders include "bundled" in error/log strings. Replace with the consolidation strategy name:

| File | Current | Replacement |
|------|---------|-------------|
| All `*_Single.res` builders | `"forEventCollector(bundled): ..."` | `"forEventCollector(single): ..."` |
| All `*_Single.res` builders | `"forCommandTopic(bundled): ..."` | `"forCommandTopic(single): ..."` |
| `AggregateRuntime_Builder_Micro.res` | `"forCommandTopic(bundled-micro): ..."` | `"forCommandTopic(micro): ..."` |
| `AggregateRuntime_Builder_Micro.res` | `"forEventCollector(bundled-micro): ..."` | `"forEventCollector(micro): ..."` |
| All builders | `"no bundled info registered for ..."` | `"no handler registered for ..."` |

## Phase 8 — Rename guide (optional)

`docs/guides/bundled-handlers-and-platform-deployment.md` — the guide name and its internal terminology could be updated to "code-asset Lambda deployment" or simply "Lambda deployment" since this is now the only approach. Low priority; the guide content remains accurate.
