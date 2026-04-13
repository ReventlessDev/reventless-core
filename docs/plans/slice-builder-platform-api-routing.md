# Slice Builder Platform API Routing Fix

## Root cause

Phase 4b routed `inboundAppSyncResolverHook` and `dcbAppSyncResolverHook` through
`resolveTargetApi()` but left the `ApiConfig` module passed to the four slice builders
hardcoded to `appSyncApi` (the domain API):

```rescript
// Platform.res — Make() body
module ApiConfig = {
  let api    = appSyncApi     // ← always domain API, never updated
  let apiRole = appSyncApiRole
}

module StateViewSlice        = { include StateViewSlice_Builder.Make(ApiConfig) }
module AutomationSlice       = { include AutomationSlice_Builder.Make(ApiConfig) }
module OutboundTranslationSlice = { include OutboundTranslationSlice_Builder.Make(ApiConfig) }
module InboundTranslationSlice  = InboundTranslationSlice_Builder.Make(ApiConfig)
```

Because `ApiConfig.api` is a module-level binding evaluated once at `Make()` time,
`resolveTargetApi()` is never consulted for these builders.

**Observed failure** (`platform-inspector-aws`, `apiTarget=Platform`):
- Schema is pushed to the platform API (`kv3dha6ymzfcvfqn7dwsvgjb3i`, `core-api`)
- `StateViewSlice` resolvers are created on the domain API (`zpmu7llghfbrnilmmziy6pwvau`, `api`)
- AppSync returns `NotFoundException: No field named Platform_* found on type Query`
- All 6 retries in `AppSync_Resolver_Retrying` exhaust (~90 s) because the field
  genuinely does not exist on the domain API
- Dedup and retry both work correctly — the error is routing, not timing

---

## Naming cleanup (prerequisite)

Throughout `Platform.res` `Make()`, rename local variables to make the domain/platform
split explicit. No behaviour change.

| Old name | New name |
|---|---|
| `appSyncApi` | `domainApi` |
| `appSyncApiRole` | `domainApiRole` |
| `platformApiForConfig` | `platformApi` |
| `platformApiRoleForConfig` | `platformApiRole` |
| `let api = appSyncApi` (line ~211) | `let domainApi = …` |
| `let apiRole = appSyncApiRole` | `let domainApiRole = …` |

`apiConfigRef` already uses `domainApi`/`platformApi` field names — no change needed
there.

---

## Fix — thunk-based ApiConfig

`Platform.StateViewSlice.Make(PlatformOverview)` (and the other slice functor
applications) is evaluated at **module load time** — before `deployPlugin` is called.
However, the `make()` closure it produces is called **at runtime**, inside
`deployPlugin`, after `currentDeployTarget` has been set.

`resolveTargetApi()` already reads `currentDeployTarget` lazily. If `ApiConfig.api` is
a thunk `() => resolveTargetApi()` rather than a direct Output value, the builder
calls it at `make()` time and gets the correct API. No additional refs are needed.

### Step 1 — Hoist `resolveTargetApi` / `resolveTargetApiRole` before `ApiConfig`

Move both resolver helpers above `module ApiConfig` in `Platform.res`:

```rescript
let resolveTargetApi = () =>
  switch currentDeployTarget.contents {
  | Domain => domainApi
  | Platform =>
    switch apiConfigRef.contents {
    | Some({platformApi}) => platformApi
    | None => domainApi
    }
  }

let resolveTargetApiRole = () =>
  switch currentDeployTarget.contents {
  | Domain => domainApiRole
  | Platform =>
    switch apiConfigRef.contents {
    | Some({platformApiRole}) => platformApiRole
    | None => domainApiRole
    }
  }
```

### Step 2 — Change `ApiConfig` to expose thunks

```rescript
module ApiConfig = {
  // Thunks evaluated at make() time — reads currentDeployTarget set by deployPlugin.
  let api     = resolveTargetApi
  let apiRole = resolveTargetApiRole
}
```

No new refs. `currentDeployTarget` (already present) is the only mutable state.

### Step 3 — Update `deployPlugin` to use `resolveTargetApi()` for hooks

```rescript
let deployPlugin = (~version, ~plugin: module(PluginMaker), ~apiTarget=Domain) => {
  Console.log(`[Platform:deployPlugin] v${version}`)
  currentDeployTarget := apiTarget

  let targetApi     = resolveTargetApi()
  let targetApiRole = resolveTargetApiRole()
  let scheduler     = makeScheduler()
  hooks.scheduler := Some(scheduler)
  hooks.api        := Some(targetApi->wrapHookedValue)
  hooks.apiRole    := Some(targetApiRole->wrapHookedValue)

  module P = unpack(plugin)
  let pluginComponent = P.make()
  currentDeployTarget := Domain

  Pulumi.Pulumi.export("_interopMeta", ReventlessCore.Plugin_Helpers.getInteropMeta())
  let pluginOutputs = pluginComponent->ReventlessCore.Component.outputs
  ReventlessCore.Plugin_Helpers.exportPluginOutputs(pluginOutputs)
  pluginOutputs
}
```

---

## Step 4 — Update slice builder signatures (AWS layer)

Change the `Api` module argument from a direct Output to a thunk, in all four builders.

**Pattern** (same for `AutomationSlice_Builder`, `OutboundTranslationSlice_Builder`,
`InboundTranslationSlice_Builder`):

```rescript
// Before
module Make = (Api: {
  let api:     Types.AppSync.api
  let apiRole: Types.AppSync.role
}) => { ... }

// After
module Make = (Api: {
  let api:     unit -> Types.AppSync.api
  let apiRole: unit -> Types.AppSync.role
}) => { ... }
```

All internal usages of `Api.api` → `Api.api()`; `Api.apiRole` → `Api.apiRole()`.

Files:
- `reventless/reventless-aws/src/components/StateViewSlice_Builder.res`
- `reventless/reventless-aws/src/components/AutomationSlice_Builder.res`
- `reventless/reventless-aws/src/components/OutboundTranslationSlice_Builder.res`
- `reventless/reventless-aws/src/components/InboundTranslationSlice_Builder.res`

---

## Step 5 — Update core slice builders

The core `StateViewSlice_Builder` (and the automation/inbound/outbound equivalents)
receive `Api` from the AWS layer and call `Api.api` inside `make()`. Change to
call the thunk.

File: `reventless/reventless-core/src/components/StateViewSlice/StateViewSlice_Builder.res`

```rescript
// Before
let queryDb = SpecificQueryDb.make(Api.api, Api.apiRole, undefined, opts)

// After
let queryDb = SpecificQueryDb.make(Api.api(), Api.apiRole(), undefined, opts)
```

Apply the same pattern to the equivalent core builders for `AutomationSlice`,
`OutboundTranslationSlice`, and `InboundTranslationSlice`.

---

## Step 6 — In-memory platform

`Platform.res` in `reventless-in-memory` also has `ApiConfig`-equivalent plumbing. The
in-memory adapter does not create AppSync resolvers, so no resolver-routing bug exists
there. However, for symmetry and to keep the in-memory `ApiConfig` compilable against
the updated builder signatures, update it to expose `apiRef`/`apiRoleRef` refs as well
(wrapping the existing no-op values).

---

## Validation

Deploy `platform-inspector-aws` with `~apiTarget=Platform`. Expected outcome:

1. `[preResolversSchemaHook] SDL unchanged … skipping push` — hash dedup fires ✓
2. No `NotFoundException: No field named Platform_*` — resolvers land on `kv3dha6ymzfcvfqn7dwsvgjb3i` ✓
3. No retries needed for a warm schema (dedup + retry together confirmed non-racing) ✓

---

## Checklist

- [x] Rename `appSyncApi`/`appSyncApiRole` → `domainApi`/`domainApiRole` in `Platform.res`
- [x] Add `resolveTargetApiRole()` helper
- [x] Hoist `resolveTargetApi` / `resolveTargetApiRole` above `ApiConfig`
- [x] Update `ApiConfig` to expose thunks (`let api = resolveTargetApi`)
- [x] Update `deployPlugin` — use `resolveTargetApi()` for `hooks.api`/`hooks.apiRole`
- [x] Update AWS-layer builder signatures (`StateViewSlice_Builder`, `AutomationSlice_Builder`, `OutboundTranslationSlice_Builder`, `InboundTranslationSlice_Builder`, `Counter_Builder`)
- [x] Update core-layer builders — `Api.api` → `Api.api()`, `Api.apiRole` → `Api.apiRole()`
- [x] Update in-memory builders for signature compat (4 slices + `Counter_Builder`)
- [ ] Rebuild + redeploy `platform-inspector-aws`, verify no resolver 404s
