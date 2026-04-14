# Plan: Async `onPluginDeployedHook`

Make `onPluginDeployedHook` async so `exportPluginOutputs` can chain
`Output.flatMap(Output.fromPromise)` and export the resulting `Output<unit>`
at the top level of the Pulumi program. Pulumi then blocks on the hook's
Promise — and therefore on any async work the hook performs — before completing
the update.

**Scope:** One file:
`reventless/reventless-core/src/components/Plugin/Plugin_Helpers.res`

No changes required to `rescript-pulumi-pulumi` — `Output.fromPromise` and
`Output.flatMap` both already exist.

Adapter implementations that call `registerOnPluginDeployed` must update their
callbacks to return `promise<unit>` instead of `unit`.

---

## Motivation

`onPluginDeployedHook` callbacks that fire async work (e.g. HTTP calls) currently
drop their Promises — the callback type is `pluginDeployedInfo => unit`. Pulumi
has no way to track the resulting Promises, so the process can exit before they
complete.

The fix is to:
1. Change the callback type to `pluginDeployedInfo => promise<unit>`.
2. In `exportPluginOutputs`, capture the hook's return value, flatten it into
   `Output<unit>` via `Output.flatMap(Output.fromPromise)`, and export it at
   the top level so Pulumi blocks on it.

---

## Why `export` must be called in `exportPluginOutputs`, not in the callback

`Pulumi.Pulumi.export` must be called at Pulumi top-level (during program
initialisation). Calling it inside an `Output.apply` callback is silently ignored
because the resource graph is already sealed when callbacks execute.

`exportPluginOutputs` itself runs at top-level — so an `export` call there
is registered correctly:

```
exportPluginOutputs (top-level)
  → hookOutput = allOutputs->flatMap(hook(info))  // Output<promise<unit>>
                 ->flatMap(fromPromise)            // Output<unit>
  → Pulumi.Pulumi.export("_pluginDeployedSync", hookOutput)  // ← top-level ✓
```

---

## Step 1 — Change hook type in `Plugin_Helpers.res`

**File:** `reventless/reventless-core/src/components/Plugin/Plugin_Helpers.res`

### 1a — Hook ref and `registerOnPluginDeployed` (lines 475–479)

```rescript
// Before:
let onPluginDeployedHook: ref<option<pluginDeployedInfo => unit>> = ref(None)

let registerOnPluginDeployed = (hook: pluginDeployedInfo => unit) => {
  onPluginDeployedHook.contents = Some(hook)
}

// After:
let onPluginDeployedHook: ref<option<pluginDeployedInfo => promise<unit>>> = ref(None)

let registerOnPluginDeployed = (hook: pluginDeployedInfo => promise<unit>) => {
  onPluginDeployedHook.contents = Some(hook)
}
```

### 1b — `exportPluginOutputs` hook dispatch (lines 1274–1308)

```rescript
// Before:
let _ =
  (
    pluginOutputs.id,
    pluginOutputs.version,
    resolveAggregates,
    resolveReadModels,
    resolveExtensionPoints,
    resolveStateChangeSlices,
  )
  ->Pulumi.Output.all6
  ->Pulumi.Output.flatMap(((id, version, aggs, rms, eps, scs)) =>
    (
      resolveStateViewSlices,
      resolveAutomationSlices,
      resolveOutboundTranslationSlices,
      resolveInboundTranslationSlices,
      resolveDcbEventLog,
      resolveExtensionWirings,
    )
    ->Pulumi.Output.all6
    ->Pulumi.Output.apply(((svs, autos, ots, its, dcb, wirings)) => {
      let name = id->String.split("@")->Array.getUnsafe(0)
      let info: pluginDeployedInfo = {
        name,
        version,
        environment: Pulumi.Pulumi.getStackName(),
        stackName: Pulumi.Pulumi.getStackName(),
        components: Array.flat([aggs, rms, eps, scs, svs, autos, ots, its, dcb]),
        extensionWirings: wirings,
      }
      hook(info)
    })
  )

// After:
let hookOutput =
  (
    pluginOutputs.id,
    pluginOutputs.version,
    resolveAggregates,
    resolveReadModels,
    resolveExtensionPoints,
    resolveStateChangeSlices,
  )
  ->Pulumi.Output.all6
  ->Pulumi.Output.flatMap(((id, version, aggs, rms, eps, scs)) =>
    (
      resolveStateViewSlices,
      resolveAutomationSlices,
      resolveOutboundTranslationSlices,
      resolveInboundTranslationSlices,
      resolveDcbEventLog,
      resolveExtensionWirings,
    )
    ->Pulumi.Output.all6
    ->Pulumi.Output.apply(((svs, autos, ots, its, dcb, wirings)) => {
      let name = id->String.split("@")->Array.getUnsafe(0)
      let info: pluginDeployedInfo = {
        name,
        version,
        environment: Pulumi.Pulumi.getStackName(),
        stackName: Pulumi.Pulumi.getStackName(),
        components: Array.flat([aggs, rms, eps, scs, svs, autos, ots, its, dcb]),
        extensionWirings: wirings,
      }
      hook(info)   // now returns promise<unit> → Output<promise<unit>>
    })
  )
  ->Pulumi.Output.flatMap(Pulumi.Output.fromPromise)  // → Output<unit>

Pulumi.Pulumi.export("_pluginDeployedSync", hookOutput)  // top-level ✓
```

The `| None => ()` branch is unchanged. The `Pulumi.Pulumi.export` call is
inside `| Some(hook) =>` but outside any `Output.apply` callback — it executes
during program initialisation, which is Pulumi top-level.

---

## Step 2 — Build

```sh
npm run build
```

Expected: clean build. The type change is confined to `Plugin_Helpers.res` and
its callers. Any callers within core will surface as type errors here.

---

## Step 3 — Update adapter callers

All `registerOnPluginDeployed` callsites must change their callback return type
from `unit` to `promise<unit>`. Callbacks that already produce a Promise only
need to return it rather than discard it; callbacks that return `unit` must wrap
in `Promise.resolve()`.

```rescript
// Before — Promise discarded, unit returned:
ReventlessCore.Plugin_Helpers.registerOnPluginDeployed(info => {
  doAsyncWork(info)  // promise<unit>, dropped
})

// After — Promise returned:
ReventlessCore.Plugin_Helpers.registerOnPluginDeployed(info => {
  doAsyncWork(info)  // returned
})
// or with await:
ReventlessCore.Plugin_Helpers.registerOnPluginDeployed(async info => {
  await doAsyncWork(info)
})
```

---

## Step 4 — Deploy to verify

Run `pulumi up` against a stack with the hook registered. Expected:

- `pulumi up` takes longer than before (process waits for the hook Promise).
- `pulumi stack output _pluginDeployedSync` returns a value.
- Any async work performed by the hook completes before the update finishes.

---

## Checklist

- [x] Step 1a: Change `onPluginDeployedHook` ref type and `registerOnPluginDeployed` signature
- [x] Step 1b: Change `exportPluginOutputs` to capture `hookOutput`, chain `flatMap(fromPromise)`, export at top level
- [x] Step 2: Build passes
- [x] Step 3: Update all adapter callers to return `promise<unit>` (reventless-in-memory/src/Platform.res: `let _ = hook(...)` to discard promise in sync context)
- [ ] Step 4: Deploy — `pulumi up` waits, `_pluginDeployedSync` exported

---

## Fallback

If `Pulumi.Pulumi.export` inside `| Some(hook) =>` (but outside `Output.apply`)
turns out to still be ignored, the symptom is: `pulumi up` exits quickly and
`_pluginDeployedSync` is absent from stack outputs. In that case, the hook
cannot be made to block the update from the framework side — callers must use a
Pulumi dynamic resource within their `Output.apply` callback instead.
