# Dual-API Architecture Plan

This plan implements the framework-level changes required to make the dual-API split correct and fully surfaced. It covers phases that can be deployed independently.

---

## Original state (before this work)

- `Platform.res` (`reventless/reventless-aws/src/Platform.res`) exported `apiId`, `apiEndpoint`, `apiRoleArn` for the Plugin/Domain API and `coreApiId`, `coreApiRoleArn` for the Core/Platform API. `coreApiEndpoint` was never exported.
- `apiConfig` type had only `api` and `apiRole` — no separation between domain and platform APIs.
- `Admin.construct` always attached its resolvers to `appSyncApi` (the Domain API), even in split mode. The Core API received a schema push but no resolvers → every admin mutation returned null/error.
- `platformDeployedInfo` carried `apiEndpoint`, `apiRoleArn`, and `splitApiMode: bool`. No `platformApiEndpoint` field, so plugin stacks could not reach the Platform API.
- The phantom API construction in `MakeWithConfig` only reconstructed the Domain API from the stack reference. No phantom existed for the Platform API.

---

## Phase 1 — Add new stack exports alongside old ones ✓

**Goal:** New export names live alongside legacy names so new plugin stacks can read them while old stacks continue to work.

**File:** `reventless/reventless-aws/src/Platform.res`

Added alongside the existing ones (no removals):

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

Legacy names (`apiId`, `apiEndpoint`, `apiRoleArn`, `coreApiId`, `coreApiRoleArn`) are kept until Phase 5.

---

## Phase 2 — Move Admin resolvers to the Platform API ✓

**Goal:** Fix the broken split — the Platform API gets both schema AND resolvers for admin operations.

**File:** `reventless/reventless-aws/src/Platform.res`

Changed `Admin.construct()` to route to the correct API in split mode:

```rescript
let targetApi  = if Config.splitApi then coreApiOutput  else appSyncApi
let targetRole = if Config.splitApi then coreRoleOutput else appSyncApiRole
Admin.construct(~api=targetApi, ~apiRole=targetRole, ...)
```

In unified mode the behaviour is unchanged (same resource).

---

## Phase 3 — Expand `apiConfig` and `platformDeployedInfo`; add Platform API phantom ✓

### 3a. `apiConfig` type ✓

**File:** `reventless/reventless-aws/src/Platform.res`

```rescript
type apiConfig = {
  domainApi: Types.AppSync.api,
  domainApiRole: Types.AppSync.role,
  platformApi: Types.AppSync.api,      // = domainApi in unified mode
  platformApiRole: Types.AppSync.role, // = domainApiRole in unified mode
}
```

`getApiConfig` updated to populate all four fields; all callers migrated to the split field names.

### 3b. `platformDeployedInfo` type ✓

**File:** `reventless/reventless-core/src/components/Plugin/Plugin_Helpers.res`

```rescript
type platformDeployedInfo = {
  name: string,
  environment: string,
  region: string,
  domainApiEndpoint: string,    // Domain API — for application mutations
  platformApiEndpoint: string,  // Platform API — for Platform_Sync* and admin mutations
  domainApiRoleArn: string,
  platformApiRoleArn: string,
  adminResources: array<ReventlessInterop.Resource.t>,
}
```

`splitApiMode` removed. All framework construction/read sites updated.

### 3c. Platform API phantom ✓

**File:** `reventless/reventless-aws/src/Platform.res`

Phantom for the Platform API added alongside the Domain API phantom, reading the new `platformApi*` stack exports. `getApiConfig()` returns `phantomPlatformApi`/`phantomPlatformRole` for the platform fields when running from a plugin stack.

---

## Phase 4 — Platform-plugin routing and index query naming fix ✓

**Goal:** Allow individual plugins to be deployed to the Platform API. Fix index query naming bug.

### 4a — `apiTarget` type and routing ref ✓

`type apiTarget = Domain | Platform` added to `Platform.T` and `deployPlugin` signature. `currentDeployTarget` ref added inside `MakeWithConfig` for both AWS and in-memory platforms.

### 4b — Route resolver hooks to the correct API ✓

Both resolver hooks in `reventless/reventless-aws/src/Platform.res` now call `resolveTargetApi()` / `resolveTargetRole()` instead of closing over `appSyncApi` directly.

### 4c — Route schema hook and DynamoDB key namespace ✓

`preResolversSchemaHook` now selects `deploySchemaPrefix` vs `deploySchemaPlatformPrefix` and the target AppSync API based on `currentDeployTarget`.

### 4d — Fix index query naming in `QueryDbResolvers_AppSync` ✓

**File:** `reventless/reventless-aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res`

Fixed double-`By` bug by stripping a leading `by` from the index name before capitalizing:

```rescript
let stripLeadingBy = s =>
  if s->String.startsWith("by") && s->String.length > 2 {
    s->String.sliceToEnd(~start=2)
  } else { s }
let resolverName = fieldNameForSingle->String.capitalize ++ "By" ++ (index->stripLeadingBy->String.capitalize)
let fieldName    = fieldNameForSingle                    ++ "By" ++ (index->stripLeadingBy->String.capitalize)
```

**Breaking change** — clients querying by index must update field names.

---

## Phase 4e — Harmonize in-memory `deployPlugin` with `makePlatform` ✓

**Goal:** Make `deployPlugin(~apiTarget=Platform)` a first-class citizen that can be called after `makePlatform` in the same process.

**File:** `reventless/reventless-in-memory/src/Platform.res`

All three changes are inside `MakeWithConfig`.

### 4e-i — Deferred server start ✓

New exported function `startServers` added to both `Platform.T` (infra) and all implementations:

```rescript
// In split mode: starts DomainGraphQL, DomainMCP, and the platform servers.
// In unified mode and AWS: no-op (start() called inline / managed by Pulumi).
let startServers = () => {
  if Config.splitApi {
    DomainGraphQL.start()
    DomainMCP.start()
    switch platformGraphQLRef.contents {
    | Some(inst) => inst.start(~port=4001, ())
    | None => ()
    }
    switch platformMCPRef.contents {
    | Some(inst) => inst.start(~port=3002, ())
    | None => ()
    }
  }
}
```

`makePlatform` and `deployPlugin` no longer call `start()` in split mode. The caller invokes `Platform.startServers()` once after all setup is done.

### 4e-ii — Plugin QueryDb seeding from `deployPlugin` ✓

`seedPluginQueryDb` extracted as a shared helper (with lazy store init via `ensurePluginQueryDbStore`). Both `makePlatform` and `deployPlugin` call it — platform plugins are now visible in the plugin read model.

### 4e-iii — `onPluginDeployed` hook from `deployPlugin` ✓

`firePluginDeployedHooks` extracted as a shared helper. `deployPlugin` now registers `onPluginBuiltHook` before `P.make()`, collects `builtInfo`, then calls `firePluginDeployedHooks` — platform plugins fire the same deployed hooks as domain plugins.

---

## Phase 4f — Consistent domain/platform naming in in-memory Platform ✓

**Goal:** Remove the misleading `admin*` prefix from server variables; use `domain*` / `platform*` consistently throughout `reventless/reventless-in-memory/src/Platform.res`.

### What was renamed

| Old name | New name |
|---|---|
| `adminGraphQLRef` | `platformGraphQLRef` |
| `getAdminGraphQL` | `getPlatformGraphQL` |
| `adminMCPRef` | `platformMCPRef` |
| `adminGraphQL` (local) | `platformGraphQL` |
| `adminMCP` (local) | `platformMCP` |
| `registerAdminTypes/Queries/Mutations/McpResources/McpTools` | `registerPlatformTypes/…` |
| `getAdminMutationResolver` | `getPlatformMutationResolver` |
| `GraphQL_Server.*` calls | `DomainGraphQL.*` (via `module DomainGraphQL = GraphQL_Server`) |
| `MCP_Server.*` calls | `DomainMCP.*` (via `module DomainMCP = MCP_Server`) |
| `"GraphQL:Admin"` label | `"GraphQL:Platform"` |
| `"MCP:Admin"` label | `"MCP:Platform"` |

The module aliases (`module DomainGraphQL = GraphQL_Server`, `module DomainMCP = MCP_Server`) are temporary — they will be removed in Phase 6 once the source files are renamed.

---

## Phase 5 — Retire legacy stack export names ✓

**Prerequisites:** All plugin stacks that read stack reference outputs have migrated to the new field names (`domainApiId`, `domainApiEndpoint`, `platformApiId`, etc.).

**File:** `reventless/reventless-aws/src/Platform.res`

Remove:
- `Pulumi.Pulumi.export("apiId", ...)`
- `Pulumi.Pulumi.export("apiEndpoint", ...)`
- `Pulumi.Pulumi.export("apiRoleArn", ...)`
- `Pulumi.Pulumi.export("coreApiId", ...)`
- `Pulumi.Pulumi.export("coreApiRoleArn", ...)`

Remove any deprecated alias fields from `platformDeployedInfo`.

---

## Phase 6 — Symmetric domain/platform server architecture

**Goal:** Eliminate the `setRegistrationTarget` redirect hack in `GraphQL_Server.res`; create symmetric named singletons for domain and platform; make in-memory adapter routing mirror the AWS `resolveTargetApi()` pattern; remove code duplication.

**Files affected:** `reventless/reventless-in-memory/src/adapter/` and `reventless/reventless-in-memory/src/Platform.res`

---

### Current vs target architecture

**Current (in-memory):**
- `GraphQL_Server.res` — domain singleton with a `setRegistrationTarget` redirect hack
- `GraphQL_ServerInstance.res` — generic instance factory; platform server is a dynamic instance stored in `platformGraphQLRef`
- Adapters (`CommandGeneratorResolvers_GraphQL`, `InboundTranslationResolvers_GraphQL`, `QueryDbResolvers_GraphQL`) hardcode calls to `GraphQL_Server.*`
- `deployPlugin` calls `DomainGraphQL.setRegistrationTarget(Some(inst))` to redirect adapter calls to the platform server

**Current (AWS):**
- No global singleton — adapters accept `~api` as a parameter
- `Platform.res` passes `resolveTargetApi()` to adapters via hooks
- No redirect mechanism needed

**Target (in-memory, matching AWS pattern):**
- `DomainGraphQL_Server.res` — domain singleton (rename of `GraphQL_Server.res`), `setRegistrationTarget` removed
- `PlatformGraphQL_Server.res` — platform singleton (same interface, separate global state)
- `DomainMCP_Server.res` — rename of `MCP_Server.res`
- `PlatformMCP_Server.res` — platform MCP singleton
- Adapters accept `~server` parameter instead of hardcoding `GraphQL_Server.*`
- `Platform.res` adds `resolveTargetGraphQL()` (mirrors `resolveTargetApi()`); hooks pass `~server=resolveTargetGraphQL()` to adapters

---

### 6a — Extract shared GraphQL server interface type

Define `GraphQL_Server_Intf.res` with the shared record type:

```rescript
type t = {
  registerTypes: (~sdlTypes: array<string>) => unit,
  registerMutations: (~sdlFields: array<string>, ~resolvers: dict<resolverFn>) => unit,
  registerQueries: (~sdlFields: array<string>, ~resolvers: dict<resolverFn>) => unit,
  getMutationResolver: string => option<resolverFn>,
  getQueryResolver: string => option<resolverFn>,
  start: (~port: int=?, unit) => unit,
  stop: unit => unit,
  reset: unit => unit,
}
```

`GraphQL_ServerInstance.t` already has this shape — update it to match (or alias it).

---

### 6b — Create symmetric server singletons

**`DomainGraphQL_Server.res`** (rename + simplify `GraphQL_Server.res`):
- Remove `registrationTarget` ref and `setRegistrationTarget`
- Remove the redirect logic from `registerTypes`/`registerMutations`/`registerQueries`
- Keep domain-specific extras: Relay global ID utils (`encodeGlobalId`/`decodeGlobalId`), node type registry, `rebuildSchema`, `/sdl` HTTP endpoint
- Expose `asInterface: GraphQL_Server_Intf.t` — a record of the base interface functions bound to this singleton's implementations

**`PlatformGraphQL_Server.res`** (new):
- Same module-level singleton structure as `DomainGraphQL_Server`
- No Relay/node-resolver extras (admin queries are not Relay-paginated)
- Expose `asInterface: GraphQL_Server_Intf.t`

**`DomainMCP_Server.res`** (rename of `MCP_Server.res`): no logic changes, name only.

**`PlatformMCP_Server.res`** (new): same structure as `DomainMCP_Server`, separate global state.

---

### 6c — Refactor adapters to accept `~server`

Three adapter files currently hardcode `GraphQL_Server.*`:

**`CommandGeneratorResolvers_GraphQL.res`**
```rescript
// Before
let register = (~fields, ~commandSchema) => {
  ...
  GraphQL_Server.registerMutations(~sdlFields, ~resolvers)
}

// After
let register = (~fields, ~commandSchema, ~server: GraphQL_Server_Intf.t) => {
  ...
  server.registerMutations(~sdlFields, ~resolvers)
}
```
Same change for `registerDcb`.

**`InboundTranslationResolvers_GraphQL.res`**
Same pattern — add `~server: GraphQL_Server_Intf.t` and call `server.registerMutations`.

**`QueryDbResolvers_GraphQL.res`**
- Add `~server: GraphQL_Server_Intf.t` for the base registration calls (`registerTypes`, `registerQueries`)
- Relay-specific calls (`registerNodeType`, `registerNodeResolverCallback`, `nodeTypeRegistry`, `encodeGlobalId`) are domain-only — pass them via a separate optional `~relay: option<relaySupport>` parameter:
  ```rescript
  type relaySupport = {
    encodeGlobalId: (~typeName: string, ~localId: string) => string,
    registerNodeType: (~typeName: string, ~queryDbName: string) => unit,
    registerNodeResolverCallback: nodeResolverCallback => unit,
    nodeTypeRegistry: ref<dict<string>>,
  }
  ```
  Domain plugins pass `~relay=Some(DomainGraphQL_Server.relaySupport)`. Platform plugins pass `~relay=None` (no node resolution).

  **Known asymmetry:** Platform QueryDbs do not support the Relay `node(id: ID!)` query. This is intentional — admin views are not Relay-paginated. Document this limitation in a code comment on `QueryDbResolvers_GraphQL`.

---

### 6d — Update `Platform.res` routing

Replace the `setRegistrationTarget` approach with explicit routing:

```rescript
// Add alongside resolveTargetApi() pattern
let resolveTargetGraphQL = () =>
  switch currentDeployTarget.contents {
  | Domain => DomainGraphQL_Server.asInterface
  | Platform => PlatformGraphQL_Server.asInterface
  }

let resolveTargetMCP = () =>
  switch currentDeployTarget.contents {
  | Domain => DomainMCP_Server.asInterface
  | Platform => PlatformMCP_Server.asInterface
  }
```

Update hooks to pass the resolved server:
```rescript
mutationResolverHook: (~kind, ~fields, ~commandSchema) => {
  let server = resolveTargetGraphQL()
  switch kind {
  | Aggregate => CommandGeneratorResolvers_GraphQL.register(~fields, ~commandSchema, ~server)
  | Dcb => CommandGeneratorResolvers_GraphQL.registerDcb(~fieldName, ~commandSchema, ~server)
  }
},
inboundMutationResolverHook:
  InboundTranslationResolvers_GraphQL.register(~server=resolveTargetGraphQL()),
schemaTypeRegistrationHook:
  sdlTypes => resolveTargetGraphQL().registerTypes(~sdlTypes),
```

Remove `setRegistrationTarget` call from `deployPlugin`. Remove `module DomainGraphQL = GraphQL_Server` and `module DomainMCP = MCP_Server` aliases (files are now correctly named).

Update `startServers`, `makePlatform`, and `deployPlugin` to reference the four named singletons directly (`DomainGraphQL_Server`, `PlatformGraphQL_Server`, `DomainMCP_Server`, `PlatformMCP_Server`).

**MCP hook routing (gap):** The `mcpSchemaRegistrationHook` in the hooks record also needs routing — currently it calls `DomainMCP.*` directly. Add the same `resolveTargetMCP()` pass-through:
```rescript
mcpSchemaRegistrationHook: (~resources, ~tools) =>
  resolveTargetMCP().registerSchema(~resources, ~tools),
```

**`deployPlatform` split-mode routing (gap):** `deployPlatform` currently registers admin schema to `DomainGraphQL_Server` in split mode. It should route to `PlatformGraphQL_Server` instead. After Phase 6 the `currentDeployTarget` ref is set to `Platform` before `deployPlatform` runs its admin registrations, so `resolveTargetGraphQL()` / `resolveTargetMCP()` will return the platform singletons automatically.

---

### 6e — Update remaining callers

- **`TestRunner.res`**: `stopGraphQLServer` → `DomainGraphQL_Server.stop()`, `resetGraphQLServer` → `DomainGraphQL_Server.reset()`
- **`GraphQL_InMemory_Adapter.res`**: update `rebuildSchema` call to `DomainGraphQL_Server.rebuildSchema`
- **`MCP_Server.res.mjs` / `GraphQL_Server.res.mjs`**: deleted (regenerated from renamed sources)

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
- [x] Phase 4e-i: Deferred server start — `startServers` extracted; added to `Platform.T`
- [x] Phase 4e-ii: Plugin QueryDb seeding from `deployPlugin` — shared helper extracted
- [x] Phase 4e-iii: `onPluginDeployed` hook from `deployPlugin` — shared helper extracted
- [x] Phase 4f: Rename `admin*` → `platform*` / `domain*` throughout in-memory Platform
- [x] Phase 5: Remove legacy stack export names and deprecated aliases (prerequisite: all plugin stacks migrated)
- [x] Phase 6a: Extract `GraphQL_Server_Intf.t` shared interface type
- [x] Phase 6b: Create `DomainGraphQL_Server`, `PlatformGraphQL_Server`, `DomainMCP_Server`, `PlatformMCP_Server` singletons
- [x] Phase 6c: Refactor adapters to accept `~server` / `~relay` parameters
- [x] Phase 6d: Update `Platform.res` — add `resolveTargetGraphQL/MCP()`, update all hooks (GraphQL + MCP), remove `setRegistrationTarget`, fix `deployPlatform` split-mode routing
- [x] Phase 6e: Update `TestRunner.res`, `GraphQL_InMemory_Adapter.res`, and other callers
