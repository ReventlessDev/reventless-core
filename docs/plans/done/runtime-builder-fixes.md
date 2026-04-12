# Plan: Runtime Builder Fixes

**Analysis**: [docs/analysis/aws-runtime-builders-review.md](../analysis/aws-runtime-builders-review.md)

## Overview

Fix bugs and inconsistencies found in `reventless-aws/src/adapter/Runtime/`. Three correctness bugs (B1–B3) and one potential runtime bug (B4) to investigate. Remaining items are minor polish or large refactors deferred to a later step.

---

### Step 1 — Fix `StateViewSliceRuntime_Builder_Single.finish()` ignoring memory/timeout

**File**: `reventless/reventless-aws/src/adapter/Runtime/StateViewSliceRuntime_Builder_Single.res`

`finish()` computes `maxMemorySize` and `maxTimeout` from stored specs but then hardcodes `~memorySize=1024, ~timeout=30` when creating the Lambda. Replace with the computed values.

Also make `finish()` delegate to `buildLambda` (the helper already present in the file) instead of repeating the archive-building block a second time.

---

### Step 2 — Fix `AutomationSliceRuntime_Builder_Single` wrong error label

**File**: `reventless/reventless-aws/src/adapter/Runtime/AutomationSliceRuntime_Builder_Single.res`

The `forEventCollector` error message reads `"(bundled)"` — a copy-paste from `PerEventCollector`. Change to `"(single)"` to match every other Single builder.

---

### Step 3 — Add missing `finish` to EP builders

**Files**:
- `reventless/reventless-aws/src/adapter/Runtime/PluginExtensionPointRuntime_Builder.res`
- `reventless/reventless-aws/src/adapter/Runtime/ExtensionPointRuntime_Builder_PerExtensionPoint.res`

Both files export no `finish` binding. Add `let finish = () => ()` to each.

---

### Step 4 — Investigate `PUBLISH_` vs `PTA_` env var prefix inconsistency

**Files to read**:
- `reventless/reventless-aws/src/adapter/Runtime/TaskRuntime_Builder_PerBucket.res` — uses `PUBLISH_${aggName}_QUEUE_URL`
- `reventless/reventless-aws/src/adapter/Runtime/PluginExtensionPointRuntime_Builder.res` — uses `PTA_${aggName}_QUEUE_URL`
- `reventless/reventless-aws/src/adapter/Runtime/ExtensionPointRuntime_Builder_PerExtensionPoint.res` — uses `PTA_${aggName}_QUEUE_URL`
- The corresponding entry points: `TaskEntryPoint.mjs`, `PluginExtensionPointEntryPoint.mjs`, `ExtensionPointEntryPoint.mjs`

Confirm each entry point reads the prefix its builder writes. If they already match, add a comment explaining the deliberate difference. If they don't, unify to one prefix.

---

### Step 5 — Restore missing comments in `AggregateRuntime_Builder_Single_Async`

**File**: `reventless/reventless-aws/src/adapter/Runtime/AggregateRuntime_Builder_Single_Async.res`

Restore the two comment blocks present in the sync version:
- `// Extract the SQS queue from the channel parts` in `forCommandTopic`
- Section comments in `finish()`: `// Build HANDLER_CONFIG as a single JSON env var…`, `// Build AssetArchive: static re-export + user packages`

---

### Step 6 — Document PerAggregate single-Lambda intent

**File**: `reventless/reventless-aws/src/adapter/Runtime/AggregateRuntime_Builder_PerAggregate.res` (and `_Async`)

Add a comment at the top of `finish()` (or near `storedSpec`) explaining that CommandTopic and EventCollector intentionally share one Lambda per aggregate in this strategy — and that `memorySize`/`timeout` is therefore a single value rather than per-function fields like `Micro`.

---

### Step 7 — Add comment explaining `PluginRuntime_Builder` functor

**File**: `reventless/reventless-aws/src/adapter/Runtime/PluginRuntime_Builder.res`

Add a comment on the `module Make` line explaining why this builder is a functor (channel injection) while all other builders hardcode `EventCollectorChannel.DynamoDbStream`.

---

---

### Step 8 — Extract archive-building into `Util_Bundle.buildCodeArchive` (A3/B8)

The 15-line archive-building block is copy-pasted verbatim across ~14 builder files:

```rescript
let reExportCode = `export { handler } from "...EntryPoint.mjs";`
let archiveContents: dict<Pulumi.Archive.assetOrArchive> = Dict.make()
archiveContents->Dict.set("index.mjs", ...)
packageDirs->Dict.forEachWithKey((pkgRoot, pkgName) => { archiveContents->Dict.set(...) })
let code = Pulumi.Archive.assetArchive(archiveContents)
let sourceCodeHash = Util_Bundle.hashString(reExportCode ++ packageDirs->...)
```

The only variables are `entryPointModule` (the import path) and `packageDirs`.

**Part A — Add helper to `Util_Bundle`**

**File**: `reventless/reventless-aws/src/util/Util_Bundle.mjs`

Add a JS function:
```js
export function buildCodeArchive(entryPointModule, packageDirs) {
  // returns { code, sourceCodeHash }
}
```

**File**: `reventless/reventless-aws/src/util/Util_Bundle.res`

Add the ReScript binding:
```rescript
type codeArchive = {
  code: Pulumi.Archive.t,
  sourceCodeHash: string,
}

@module("./Util_Bundle.mjs")
external buildCodeArchive: (~entryPointModule: string, ~packageDirs: dict<string>) => codeArchive = "buildCodeArchive"
```

**Part B — Replace duplicated block in all builder files**

Files to update (all in `reventless/reventless-aws/src/adapter/Runtime/`):

1. `AggregateRuntime_Builder_Single.res` — in `finish()`
2. `AggregateRuntime_Builder_Single_Async.res` — in `finish()`
3. `AggregateRuntime_Builder_PerAggregate.res` — in `finish()` per-aggregate loop
4. `AggregateRuntime_Builder_PerAggregate_Async.res` — same
5. `AggregateRuntime_Builder_Micro.res` — in `finish()` per-function (three times: CommandTopic, EventCollector, CommandGenerator)
6. `AggregateRuntime_Builder_Micro_Async.res` — same
7. `StateViewSliceRuntime_Builder_Single.res` — inside `buildLambda` helper
8. `EventCollectorRuntime_Builder_Single.res` — in `finish()`
9. `EventCollectorRuntime_Builder_PerEventCollector.res` — in `forEventCollector`
10. `AutomationSliceRuntime_Builder_Single.res` — in `finish()`
11. `SideEffectHandlerRuntime_Builder_Single.res` — in `finish()`
12. `TaskRuntime_Builder_PerBucket.res` — in `forBucketCallback`
13. `PluginExtensionPointRuntime_Builder.res` — in `forCommandTopic`
14. `ExtensionPointRuntime_Builder_PerExtensionPoint.res` — in `forCommandTopic`
15. `PluginRuntime_Builder.res` — in `forDcbCommandTopic` (and possibly `forPluginEventCollector`)

In each file, replace the block with:
```rescript
let {code, sourceCodeHash} = Util_Bundle.buildCodeArchive(
  ~entryPointModule="@reventlessdev/reventless-aws/src/adapter/Runtime/XxxEntryPoint.mjs",
  ~packageDirs,
)
```

---

## Status

- [x] Step 1 — Fix StateViewSlice memory/timeout + use buildLambda
- [x] Step 2 — Fix AutomationSlice error label
- [x] Step 3 — Add missing `finish` to EP builders
- [x] Step 4 — Investigate PUBLISH_ vs PTA_ prefix (prefixes match their own entry points; difference is deliberate — comment added to TaskRuntime_Builder_PerBucket)
- [x] Step 5 — Restore comments in Single_Async
- [x] Step 6 — Document PerAggregate single-Lambda intent
- [x] Step 7 — Document PluginRuntime_Builder functor reason
- [x] Step 8 — Extract archive-building into `Util_Bundle.buildCodeArchive`
