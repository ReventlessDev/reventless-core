# Dual-API Architecture Plan

This plan implements the framework-level changes required to make the dual-API split correct and fully surfaced. It covers four phases that can be deployed independently.

---

## Current state

- `Platform.res` (`reventless/reventless-aws/src/Platform.res`) exports `apiId`, `apiEndpoint`, `apiRoleArn` for the Plugin/Domain API and `coreApiId`, `coreApiRoleArn` for the Core/Platform API. `coreApiEndpoint` is never exported.
- `apiConfig` type (line 16–19 of `Platform.res`) has only `api` and `apiRole` — no separation between domain and platform APIs.
- `Admin.construct` always attaches its resolvers to `appSyncApi` (the Domain API), even in split mode. The Core API receives a schema push but no resolvers → every admin mutation returns null/error.
- `platformDeployedInfo` (`Plugin_Helpers.res` lines 489–498) carries `apiEndpoint`, `apiRoleArn`, and `splitApiMode: bool`. There is no `platformApiEndpoint` field, so plugin stacks cannot reach the Platform API.
- The phantom API construction in `MakeWithConfig` only reconstructs the Domain API from the stack reference. No phantom exists for the Platform API.

---

## Phase 1 — Add new stack exports alongside old ones

**Goal:** New export names live alongside legacy names so new plugin stacks can read them while old stacks continue to work.

**File:** `reventless/reventless-aws/src/Platform.res`

Add these exports alongside the existing ones (no removals):

```rescript
// Domain API — new names
Pulumi.Pulumi.export("domainApiId",       appSyncApi->Pulumi.Output.flatMap(api => api.id))
Pulumi.Pulumi.export("domainApiEndpoint", appSyncApi->Pulumi.Output.flatMap(api =>
  api.uris->Pulumi.Output.apply(uris => uris.graphQL)))
Pulumi.Pulumi.export("domainApiRoleArn",  appSyncApiRole->Pulumi.Output.flatMap(role => role.arn))

// Platform API — new names (coreApiEndpoint was previously missing)
Pulumi.Pulumi.export("platformApiId",       coreApiOutput->Pulumi.Output.flatMap(api => api.id))
Pulumi.Pulumi.export("platformApiEndpoint", coreApiOutput->Pulumi.Output.flatMap(api =>
  api.uris->Pulumi.Output.apply(uris => uris.graphQL)))
Pulumi.Pulumi.export("platformApiRoleArn",  coreRoleOutput->Pulumi.Output.flatMap(role => role.arn))
```

In unified mode (`splitApi = false`) the platform exports point to the same resource as the domain exports.

Legacy names (`apiId`, `apiEndpoint`, `apiRoleArn`, `coreApiId`, `coreApiRoleArn`) are kept until Phase 4.

---

## Phase 2 — Move Admin resolvers to the Platform API

**Goal:** Fix the broken split — the Platform API gets both schema AND resolvers for admin operations.

**File:** `reventless/reventless-aws/src/Platform.res`

Change the `Admin.construct()` call at line 761 from:

```rescript
Admin.construct(~api=appSyncApi, ~apiRole=appSyncApiRole, ...)
```

to:

```rescript
let targetApi  = if Config.splitApi then coreApiOutput  else appSyncApi
let targetRole = if Config.splitApi then coreRoleOutput else appSyncApiRole
Admin.construct(~api=targetApi, ~apiRole=targetRole, ...)
```

This requires `coreApiOutput` and `coreRoleOutput` to be defined before `Admin.construct()` is called — reorder the construction sequence if necessary.

In unified mode the behaviour is unchanged (same resource).

---

## Phase 3 — Expand `apiConfig` and `platformDeployedInfo`; add Platform API phantom

### 3a. `apiConfig` type

**File:** `reventless/reventless-aws/src/Platform.res` (lines 16–19)

```rescript
// Before
type apiConfig = {
  api: Types.AppSync.api,
  apiRole: Types.AppSync.role,
}

// After
type apiConfig = {
  domainApi: Types.AppSync.api,
  domainApiRole: Types.AppSync.role,
  platformApi: Types.AppSync.api,      // = domainApi in unified mode
  platformApiRole: Types.AppSync.role, // = domainApiRole in unified mode
}
```

Update `getApiConfig` to populate all four fields. In unified mode:
```rescript
domainApi = appSyncApi,  platformApi = appSyncApi
domainApiRole = appSyncApiRole, platformApiRole = appSyncApiRole
```

Update all callers of `apiConfig.api` / `apiConfig.apiRole` to use the appropriate split field.

### 3b. `platformDeployedInfo` type

**File:** `reventless/reventless-core/src/components/Plugin/Plugin_Helpers.res` (lines 489–498)

```rescript
// Before
type platformDeployedInfo = {
  name: string,
  environment: string,
  region: string,
  apiId: string,
  apiEndpoint: string,
  apiRoleArn: string,
  splitApiMode: bool,
  adminResources: array<ReventlessInterop.Resource.t>,
}

// After
type platformDeployedInfo = {
  name: string,
  environment: string,
  region: string,
  domainApiEndpoint: string,    // Domain API — for application mutations
  platformApiEndpoint: string,  // Platform API — for Platform_Sync* and admin mutations
  domainApiRoleArn: string,     // advisory — exported, not reused by plugin stacks
  platformApiRoleArn: string,   // metadata — records the Platform API execution role
  adminResources: array<ReventlessInterop.Resource.t>,
}
```

`splitApiMode` is removed — callers that need to know whether the APIs are split compare the two endpoint strings. `apiId` and `apiEndpoint` legacy aliases may be retained as deprecated fields during the transition; remove in Phase 4.

Update all framework code that constructs or reads `platformDeployedInfo` to use the new field names.

### 3c. Platform API phantom

**File:** `reventless/reventless-aws/src/Platform.res`

Add a phantom for the Platform API alongside the existing Domain API phantom, reading from the new stack exports added in Phase 1:

```rescript
let platformApiIdOutput       = stackRef->Pulumi.StackReference.getOutput("platformApiId")
let platformApiEndpointOutput = stackRef->Pulumi.StackReference.getOutput("platformApiEndpoint")
let platformApiRoleArnOutput  = stackRef->Pulumi.StackReference.getOutput("platformApiRoleArn")
```

Construct `phantomPlatformApi` and `phantomPlatformRole` using the same approach as the existing Domain API phantom — follow the pattern already established for `phantomApi` / `phantomRole` in `MakeWithConfig`.

`getApiConfig()` returns `phantomPlatformApi` / `phantomPlatformRole` for the platform fields when running from a plugin stack.

---

## Phase 4 — Retire legacy export names

**Prerequisites:** All plugin stacks that read stack reference outputs have migrated to the new field names.

**File:** `reventless/reventless-aws/src/Platform.res`

Remove:
- `Pulumi.Pulumi.export("apiId", ...)`
- `Pulumi.Pulumi.export("apiEndpoint", ...)`
- `Pulumi.Pulumi.export("apiRoleArn", ...)`
- `Pulumi.Pulumi.export("coreApiId", ...)`
- `Pulumi.Pulumi.export("coreApiRoleArn", ...)`

Remove any deprecated alias fields from `platformDeployedInfo` retained during Phase 3.

Remove `splitApiMode` read sites (already removed from the type in Phase 3).

---

## Phase 4 — Platform-plugin routing and index query naming fix

**Goal:** Allow individual plugins to be deployed to the Platform API instead of the Domain API. Fix the index query naming bug in `QueryDbResolvers_AppSync` that produces unprefixed, sometimes double-`By` field names.

### 4a — `apiTarget` type and routing ref

**File:** `reventless/reventless-infra/src/types/Platform.res`

Add the type and update `deployPlugin`:

```rescript
type apiTarget = Domain | Platform

// update signature:
let deployPlugin: (~version: string, ~plugin: module(PluginMaker), ~target: apiTarget=?) => pluginOutputs
```

**File:** `reventless/reventless-aws/src/Platform.res`

Add a module-level routing ref inside `MakeWithConfig` (alongside `apiConfigRef` and `splitApiOutputsRef`):

```rescript
let currentDeployTarget: ref<apiTarget> = ref(Domain)
```

Update `deployPlugin` to accept and apply the target:

```rescript
let deployPlugin = (~version, ~plugin: module(PluginMaker), ~target: apiTarget=Domain) => {
  currentDeployTarget := target
  // ... existing body unchanged ...
  currentDeployTarget := Domain  // reset after build
  pluginOutputs
}
```

**File:** `reventless/reventless-in-memory/src/Platform.res`

Same changes — add `currentDeployTarget` ref and update `deployPlugin` signature. The in-memory resolver and schema hooks need the same branching (see 4b).

### 4b — Route resolver hooks to the correct API

**File:** `reventless/reventless-aws/src/Platform.res`

Both resolver hooks currently close over `appSyncApi`. Add a helper inside `MakeWithConfig` that reads the current target:

```rescript
let resolveTargetApi = () =>
  switch currentDeployTarget.contents {
  | Domain => appSyncApi
  | Platform =>
    switch apiConfigRef.contents {
    | Some({platformApi}) => platformApi
    | None => appSyncApi  // fallback: platform API not yet constructed
    }
  }

let resolveTargetRole = () =>
  switch currentDeployTarget.contents {
  | Domain => appSyncApiRole
  | Platform =>
    switch apiConfigRef.contents {
    | Some({platformApiRole}) => platformApiRole
    | None => appSyncApiRole
    }
  }
```

Update the two hooks:

```rescript
inboundAppSyncResolverHook: ({runtime, fieldNames, externalInputSchemas: _, opts}) => {
  InboundTranslationResolvers_AppSync.make(
    ~api=resolveTargetApi(),   // was: ~api=appSyncApi
    ~runtime=runtimeTyped,
    ~fieldNames,
    ~opts,
  )
},
dcbAppSyncResolverHook: ({runtime, fieldNames, tags, opts}) => {
  CommandGeneratorResolvers_AppSync.makeDcb(
    ~api=resolveTargetApi(),   // was: ~api=appSyncApi
    ~runtime=runtimeTyped,
    ~fieldNames,
    ~tags,
    ~opts,
  )
},
```

### 4c — Route schema hook to the correct API

**File:** `reventless/reventless-aws/src/Platform.res`

`preResolversSchemaHook` currently always writes to `"deploy-schema:{name}"` in DynamoDB and pushes to `appSyncApi`. Platform plugins must use a separate DynamoDB key namespace and push to `coreApiOutput`.

Add a second prefix constant:

```rescript
let deploySchemaPrefix = "deploy-schema:"
let deploySchemaPlatformPrefix = "deploy-schema-platform:"
```

At the top of `preResolversSchemaHook`, select the active prefix and target API:

```rescript
preResolversSchemaHook: (~name, pluginFragment) => {
  let (schemaPrefix, targetApi) = switch currentDeployTarget.contents {
  | Domain => (deploySchemaPrefix, appSyncApi)
  | Platform =>
    let api = switch apiConfigRef.contents {
    | Some({platformApi}) => platformApi
    | None => appSyncApi
    }
    (deploySchemaPlatformPrefix, api)
  }
  // replace all uses of `deploySchemaPrefix` with `schemaPrefix`
  // replace all uses of `appSyncApi` with `targetApi`
  // the filter expression prefix, put/scan keys, and startSchemaCreation target all use these variables
```

For Platform target, stitch with `adminBaseFragment` (not `emptyBaseFragment`) because the Platform API owns admin operations:

```rescript
let baseFragment = switch currentDeployTarget.contents {
| Domain =>
  if Config.splitApi { emptyBaseFragment }
  else { AppSync_Adapter.injectAwsAuthAll(ReventlessCore.AdminApi.baseFragment(...), ...) }
| Platform =>
  AppSync_Adapter.injectAwsAuthAll(ReventlessCore.AdminApi.baseFragment(~cloner=Config.cloner), ~group="Admin")
}
```

### 4d — Fix index query naming in `QueryDbResolvers_AppSync`

**File:** `reventless/reventless-aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res`

Current code at line 169 inside `resourcesMaker`:

```rescript
let name = name ++ ("By" ++ index->String.capitalize)
```

This uses the raw entity name (no plugin prefix) and capitalizes the full index string, producing `"SchemaHistoryByByPlugin"` when the index is `"byPlugin"`.

Replace with:

```rescript
let stripLeadingBy = s =>
  if s->String.startsWith("by") && s->String.length > 2 {
    s->String.sliceToEnd(~start=2)
  } else {
    s
  }
let resolverName =
  fieldNameForSingle->String.capitalize ++
  "By" ++
  (index->stripLeadingBy->String.capitalize)
let fieldName =
  fieldNameForSingle ++
  "By" ++
  (index->stripLeadingBy->String.capitalize)
```

Update the resolver and field references on lines 173 and 178 to use `resolverName` and `fieldName` respectively (replacing `name` in both positions).

**Note:** The schema SDL (generated by reventless-ppx from `@index` annotations) must declare the same field names. Verify that the ppx-generated schema uses the same `fieldNameForSingle + "By" + stripLeadingBy(index)` pattern, and update it if not. This is a **breaking change** — any client querying by index must update field names.

---

## Phase 5 — Retire legacy export names

**Prerequisites:** All plugin stacks that read stack reference outputs have migrated to the new field names.

**File:** `reventless/reventless-aws/src/Platform.res`

Remove:
- `Pulumi.Pulumi.export("apiId", ...)`
- `Pulumi.Pulumi.export("apiEndpoint", ...)`
- `Pulumi.Pulumi.export("apiRoleArn", ...)`
- `Pulumi.Pulumi.export("coreApiId", ...)`
- `Pulumi.Pulumi.export("coreApiRoleArn", ...)`

Remove any deprecated alias fields from `platformDeployedInfo` retained during Phase 3.

Remove `splitApiMode` read sites (already removed from the type in Phase 3).

---

## Checklist

- [x] Phase 1: Add `domainApi*` and `platformApi*` exports to `Platform.res`
- [x] Phase 2: Reroute `Admin.construct` to Platform API in split mode
- [x] Phase 3a: Expand `apiConfig` type and update `getApiConfig`
- [x] Phase 3b: Expand `platformDeployedInfo` type and update all construction/read sites
- [x] Phase 3c: Add phantom Platform API construction
- [x] Phase 4a: Add `apiTarget` type to `Platform.T` and `deployPlugin` signature
- [x] Phase 4b: Route resolver hooks via `currentDeployTarget` ref
- [x] Phase 4c: Route schema hook and DynamoDB key namespace via `currentDeployTarget` ref
- [x] Phase 4d: Fix index query naming in `QueryDbResolvers_AppSync`
- [ ] Phase 5: Remove legacy export names and deprecated aliases
