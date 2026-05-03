# Plan: DcbCommandTopic Lambda — Pass Behavior to StateChangeSlice_Callback.Make

## Problem

`DcbCommandTopicEntryPoint.mjs` calls the curried `StateChangeSlice_Callback.Make` functor with only the Spec module:

```js
// reventless-aws/src/adapter/Runtime/DcbCommandTopicEntryPoint.mjs:81
const sliceCallback = stateChangeSliceCallbackMake(patchedSpec);
// ...
return sliceCallback.handleCommands(sharedDcbEventLogOps, decodedStream);  // TypeError
```

The compiled functor is `Make(Spec)(Behavior)` (see `StateChangeSlice_Callback.res.mjs:17` — `function Make(Spec) { return Behavior => { ... } }`). Passing only `Spec` returns the partially-applied function; the entry point then tries to read `.handleCommands` on a function and fails:

```
TypeError: sliceCallback.handleCommands is not a function
  at jsonHandler (.../DcbCommandTopicEntryPoint.mjs:97:28)
```

This kills every DCB StateChangeSlice mutation at runtime. The mutation resolver returns `null`, AppSync rejects it (`Cannot return null for non-nullable type 'String'`), and the caller gets no acknowledgement of command publication.

The runtime config currently carries only the Spec module path (`stateChangeSliceModules`). The Behavior module path is never persisted, so the Lambda has no way to load it at cold start even though `Behavior.moduleUrl` is available where the slice is registered.

## Fix

Thread the Behavior module path from registration through the runtime config into the Lambda entry point, then apply both stages of the curried functor.

### Step 1 — Carry Behavior path through registration ✅

File: `reventless-aws/src/adapter/Runtime/PluginRuntime_Builder.res`

Done. Added named record type and updated registration signature:

```rescript
type sliceModulePaths = {
  specPath: string,
  behaviorPath: string,
}

let registeredSliceModulePaths: array<sliceModulePaths> = []

let registerStateChangeSliceSpec = (~specPath: string, ~behaviorPath: string) => {
  let _ = registeredSliceModulePaths->Array.push({specPath, behaviorPath})
}
```

`registerDcbConfig`'s `~stateChangeSliceSpecPaths` arg also renamed to `~stateChangeSliceModulePaths` and re-typed to `array<sliceModulePaths>`. No external callers, so the API rename is safe.

The original function name (`registerStateChangeSliceSpec`) was kept rather than renamed — the rename suggestion in the plan was optional and the existing name still reads correctly with named labels.

### Step 2 — Pass Behavior path from the AWS StateChangeSlice builder ✅

File: `reventless-aws/src/components/StateChangeSlice_Builder.res`

Done. `Behavior.moduleUrl` is now resolved via `Util_Bundle.getModuleSpecifier` and passed alongside the spec path:

```rescript
PluginRuntime_Builder.registerStateChangeSliceSpec(
  ~specPath=Util_Bundle.getModuleSpecifier(Spec.moduleUrl),
  ~behaviorPath=Util_Bundle.getModuleSpecifier(Behavior.moduleUrl),
)
```

### Step 3 — Emit both paths in HANDLER_CONFIG ✅

File: `reventless-aws/src/adapter/Runtime/PluginRuntime_Builder.res`

Done. The `stateChangeSliceModules` field is now `Array<{spec: string, behavior: string}>`:

```rescript
let sliceModulesJson =
  allSlicePaths
  ->Array.map(({specPath, behaviorPath}) => {
    let s = specPath->JSON.stringifyAny->Option.getOr(`""`)
    let b = behaviorPath->JSON.stringifyAny->Option.getOr(`""`)
    `{"spec":${s},"behavior":${b}}`
  })
  ->Array.join(",")

`{"dcbEventLogTableName":"${table}","queueUrl":"${queueUrl}","pluginName":${pluginName},"stateChangeSliceModules":[${sliceModulesJson}]}`
```

The `packageDirs` loop now enumerates both `specPath` and `behaviorPath` so the Lambda zip contains both modules (in practice they're usually the same package, but the dict dedupes safely).

### Step 4 — Apply both arguments in the entry point ✅

File: `reventless-aws/src/adapter/Runtime/DcbCommandTopicEntryPoint.mjs`

Done. Cold-start loop destructures `{spec, behavior}`, imports both, and applies the curried functor:

```js
await Promise.all(config.stateChangeSliceModules.map(async ({ spec, behavior }) => {
  const specModule = await dynamicImport(spec);
  const behaviorModule = await dynamicImport(behavior);
  const patchedSpec = patchSpecId(specModule);
  const sliceCallback = stateChangeSliceCallbackMake(patchedSpec)(behaviorModule);
  // ...rest unchanged
}));
```

`patchSpecId` is applied to the spec only. The behavior module is passed through as-is — `StateChangeSlice_Callback.Make`'s second stage reads `moduleUrl`, `initialState`, `evolve`, and `decide` from it, none of which need patching. If a future change requires patching, add a `patchBehaviorId` helper rather than reusing `patchSpecId`.

### Step 5 — Verify across all StateChangeSlice builders ✅

Verified: `grep -rn 'registerStateChangeSliceSpec'` in src yields exactly one caller — `reventless-aws/src/components/StateChangeSlice_Builder.res`. `registerDcbConfig`'s `stateChangeSliceModulePaths` arg also has zero external callers (would only fire if someone manually registered specs without going through the builder).

`InMemory` and other non-AWS runtime entry points are not affected — they bind Spec and Behavior at build time via the same functor application (no JSON config indirection).

### Step 6 — Cold-start integration test ⏸ Deferred

Not implemented in this change. The current entry point hardcodes the DynamoDB runtime imports (`DcbEventLogStorage_DynamoDb_Runtime`, `CommandTopicChannel_SQS_Runtime`), so a true integration test would require either:
- Refactoring the entry point to accept an injected storage/queue adapter (so it could be wired with the in-memory DcbEventLog under test), or
- Mocking the DynamoDB SDK / SQS layer at the Jest level.

Both options expand scope beyond this fix. A lighter regression-only test — asserting `stateChangeSliceCallbackMake(spec)(behavior).handleCommands` is a function — would catch the original bug without that complexity.

**Follow-up:** decide whether to add the lighter regression test or do the full DI refactor; track separately.

## Migration

The config shape change is breaking: any deployed Lambda still running with the old `stateChangeSliceModules: string[]` payload will fail to parse the new `{spec, behavior}` objects, and a new Lambda reading the new shape cannot consume the old one. Both must roll forward together. Since the entry point is shipped inside the same Lambda zip the runtime builder produces, a single `pulumi up` after this change replaces both atomically — no staged migration is needed.

## Out of Scope

- AutomationSlice, InboundTranslationSlice, OutboundTranslationSlice — they have their own entry points and may have separate functor-application bugs to audit, but each should ship as its own plan.
- The dynamic-resolver / schema-replacement state-divergence issue (resolvers deleted by AppSync but still in Pulumi state) is a separate concern in `AppSync_Resolver_Retrying`'s diff/refresh logic.
