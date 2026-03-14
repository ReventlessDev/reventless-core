# Plan: Hybrid API/MCP Schema Split (Core vs Plugins)

**Based on:** `docs/analysis/api-schema-split-core-vs-plugins.md`
**Scope:** In-memory platform (Phases 1–2) + AWS platform (Phase 3).

## Goal

Split the GraphQL and MCP servers so core administrative schema and plugin business domain schema are generated independently. By default, serve everything from a single endpoint (no behavioral change). When `splitApi=true`, serve core and plugin schemas on separate ports.

## Key Insight

The existing `GraphQL_Server.res` and `MCP_Server.res` singletons already act as the **plugin server** — all resolver modules register into them via hooks during plugin construction. Core schema is registered separately in `makePlatform()`. This means:

- Singletons stay unchanged (they are the plugin servers)
- For split mode, create **additional** core instances using new factory modules
- No changes needed to resolver modules or hooks

---

## Step 1: Create `GraphQL_ServerInstance` factory

**File:** `reventless/reventless-in-memory/src/adapter/GraphQL_ServerInstance.res` (new)

Closure-based factory that creates independent GraphQL server instances with isolated registries. Returns a record with all server operations. Used by Platform to create dedicated core server instances in split mode.

- [x] Done

## Step 2: Create `MCP_ServerInstance` factory

**File:** `reventless/reventless-in-memory/src/adapter/MCP_ServerInstance.res` (new)

Same factory pattern for MCP. Creates independent MCP server instances with isolated tool/resource registries.

- [x] Done

## Step 3: Add split config to `Platform.MakeWithConfig`

**File:** `reventless/reventless-in-memory/src/Platform.res` (modify)

Extended `Config` module type with `splitApi: bool`. Updated `Make` default to pass `splitApi = false`.

- [x] Done

## Step 4: Route core registrations in `makePlatform`

**File:** `reventless/reventless-in-memory/src/Platform.res` (modify)

When `splitApi=true`, create `GraphQL_ServerInstance` and `MCP_ServerInstance` for core schema. Helper functions (`registerCoreTypes`, `registerCoreMutations`, `registerCoreQueries`, `registerCoreMcpResources`, `registerCoreMcpTools`, `getCoreMutationResolver`) route registrations to the correct target:
- Unified mode: helpers delegate to `GraphQL_Server` / `MCP_Server` singletons
- Split mode: helpers delegate to dedicated core instances

Start servers:
- Unified: one GraphQL (4000) + one MCP (3001) as before
- Split: plugin GraphQL (4000) + core GraphQL (4001) + plugin MCP (3001) + core MCP (3002)

- [x] Done

## Step 5: Build and verify

- `npm run build` — zero warnings, all packages compile
- `npm test` — 94 suites, 783 tests pass, no regressions
- Default behavior (`splitApi=false`) is identical to previous behavior

- [x] Done

## Step 6: Add integration test for split mode

**Files:**
- `reventless/reventless-in-memory/tests/SplitApiFixtures.res` (new)
- `reventless/reventless-in-memory/tests/SplitApiTest.res` (new)

Tests the split routing pattern by directly using `GraphQL_Server` (singleton) and `GraphQL_ServerInstance` (factory) — mirrors what `makePlatform(splitApi=true)` does:
- Core schema registers into `GraphQL_ServerInstance` (isolated core server)
- Plugin schema registers into `GraphQL_Server` singleton (plugin server)
- Verifies no cross-contamination via `diagnostics()`

10 tests across 2 describe blocks:
- Plugin singleton: has plugin fields, no core fields (4 tests)
- Core instance: has core fields, no plugin fields, types registered, no mismatches (6 tests)

MCP split is structurally identical but not tested here due to Jest ESM incompatibility with the MCP SDK dependency chain (zod, @hono/node-server).

- [x] Done

## Step 7: Update documentation

**File:** `docs/guides/platform-and-plugin-guide.md` (modify)

Added "Split API mode" section under Configuration Reference:
- `MakeWithConfig` usage with `splitApi = true`
- Port assignment table (unified vs split)
- When to use split mode (security, AI agents, scaling)
- What changes in split mode (core → dedicated instances, plugin → singletons unchanged)
- Added to Table of Contents

- [x] Done

---

## Phase 3: AWS Platform Split

### Step 8: Parameterize `AppSync_Adapter` for split mode

**No changes needed.** `AppSync_Adapter` already supports creating one API per `makeApiResource` call. The split is handled entirely at the Platform level — calling `makeApiResource` twice (once for core, once for plugins) is sufficient. The adapter's `updateSchema`, `injectAwsAuth`, and `injectAwsAuthAll` functions work unchanged for both APIs.

- [x] Done (no-op — adapter already supports this)

### Step 9: Add `splitApi` config to AWS `Platform.res`

**File:** `reventless/reventless-aws/src/Platform.res` (modify)

Added `MakeWithConfig` functor mirroring the in-memory pattern:

- Takes `Config: { let splitApi: bool }` as second functor parameter
- `Make` refactored to delegate to `MakeWithConfig` with `splitApi = false`
- When `splitApi=true`:
  - `Api.Make` overrides the user-provided `baseFragment` with an empty fragment so plugin API has no core fields
  - `makePlatform` creates a dedicated core AppSync API via `AppSync_Adapter.makeApiResource` and pushes core schema (base fragment + Admin auth, no plugin fragments)
- When `splitApi=false` (default): identical to previous behavior — single API, `makePlatform` is a no-op

- [x] Done

### Step 10: Split MCP Lambda config generation

**File:** `reventless/reventless-aws/src/adapter/Mcp/MCP_Lambda.res` (modify)

Added `generateCoreConfig` convenience function:

- Calls `generateConfig` with `CoreApi.mutationEntries` + `PluginBaseFragment.queryEntries` (core-only tools/resources)
- Server name gets `-core` suffix for identification
- Plugin config generation is unchanged — `generateConfig` already works per-plugin
- `commandTopicArns` and `queryDbTableNames` default to empty (populated when Lambda Function URL deployment is wired in Step 13)

The existing `generateConfig` didn't need splitting — it already accepts arbitrary entries. The split is about calling it with the right entries (core vs plugin), which `generateCoreConfig` now provides.

- [x] Done

### Step 11: Update Pulumi stack outputs

**File:** `reventless/reventless-aws/src/Platform.res` (modify)

Added module-level `splitApiOutputs` type, ref, and `getSplitApiOutputs()` accessor outside the functor. `makePlatform` populates the ref when `splitApi=true` with `coreApi` and `coreRole` outputs.

Users access the core API in their entry point:
```rescript
switch Platform.getSplitApiOutputs() {
| Some({coreApi}) =>
  let coreApiId = coreApi->Pulumi.Output.apply(api => api.id)
  let coreApiUrl = coreApi->Pulumi.Output.apply(api => api.uris)->Pulumi.Output.apply(u => u.graphQL)
| None => ()
}
```

Cross-stack references (`Interstack`) do not need updating — the interstack system queries plugin-level exports (`"plugin"`, `"tasks"`, `"eventMappers"`), not API endpoints. The core API is only relevant within the Core stack itself.

MCP URLs (`coreMcpUrl` / `pluginMcpUrl`) deferred to Step 13 (Lambda Function URL bindings).

- [x] Done

### Step 12: AWS integration tests

Verify split mode works end-to-end:

- Core AppSync API responds to `Core_Plugin` / `Core_Plugins` queries and `Core_Plugin_Activate` / `Core_Plugin_Deactivate` / `Core_Clone` mutations
- Plugin AppSync API responds to plugin-contributed queries/mutations only
- No cross-contamination — plugin fields absent from core API introspection, core fields absent from plugin API
- Unified mode (`splitApi=false`) behaves identically to current behavior

- [ ] Done

### Step 13: MCP Lambda Function URL support (prerequisite)

**File:** `rescript/rescript-pulumi-aws/` (modify — add bindings)

Implement Pulumi bindings for AWS Lambda Function URLs:

- `aws.lambda.FunctionUrl` resource — creates a Function URL for a Lambda
- Required before MCP split can be deployed (Step 10 generates the config, this step enables deployment)
- Currently marked as placeholder in `MCP_Lambda.res`

- [ ] Done

---

## Port Assignments

| Mode | Service | Port |
|------|---------|------|
| `splitApi=false` (default) | GraphQL (unified) | 4000 |
| `splitApi=false` (default) | MCP (unified) | 3001 |
| `splitApi=true` | GraphQL (plugin) | 4000 |
| `splitApi=true` | GraphQL (core) | 4001 |
| `splitApi=true` | MCP (plugin) | 3001 |
| `splitApi=true` | MCP (core) | 3002 |

## Files Changed

| File | Action | Package |
|------|--------|---------|
| `adapter/GraphQL_ServerInstance.res` | New (factory) | reventless-in-memory |
| `adapter/MCP_ServerInstance.res` | New (factory) | reventless-in-memory |
| `Platform.res` | Extend config + split wiring | reventless-in-memory |
| `tests/SplitApiFixtures.res` | New (test fixtures) | reventless-in-memory |
| `tests/SplitApiTest.res` | New (10 tests) | reventless-in-memory |
| `package.json` | Add MCP SDK moduleNameMapper | reventless-in-memory |
| `components/Api/AppSync_Adapter.res` | No changes needed | reventless-aws |
| `Platform.res` | Add MakeWithConfig + splitApi wiring | reventless-aws |
| `adapter/Mcp/MCP_Lambda.res` | Split config generation | reventless-aws |
| `platform-and-plugin-guide.md` | AWS split mode + stack outputs docs | doc |
| Lambda Function URL bindings | New (Pulumi bindings) | rescript-pulumi-aws |

## What Was NOT Changed (by design)

- `GraphQL_Server.res` — unchanged, continues as plugin server singleton
- `MCP_Server.res` — unchanged, continues as plugin MCP server singleton
- Resolver registration modules — unchanged, they register into `GraphQL_Server` which is the plugin server
- Hooks in `Plugin_Helpers` — unchanged, they fire through the same code paths

## Risk Assessment

- **Low risk:** Default behavior (`splitApi=false`) is identical to previous behavior — same singletons, same ports.
- **No changes to resolver modules:** Plugin schema always goes into the singletons. Core schema conditionally goes into singletons (unified) or dedicated instances (split).
- **Mitigation:** Split mode is opt-in. Factory modules have no side effects at import time.

### AWS-specific risks (Phase 3)

- **Medium risk:** Two AppSync APIs doubles infrastructure cost for the API layer. Backing resources (DynamoDB, SQS, Lambda) remain shared.
- **MCP blocked on Function URL bindings:** Step 10 generates configs but deployment requires Step 13 (Pulumi bindings). These can proceed in parallel.
- **Cross-stack references:** Not affected — the interstack system queries plugin-level exports (`"plugin"`, `"tasks"`, `"eventMappers"`), not API endpoints. Core API outputs are accessed via `getSplitApiOutputs()` within the Core stack only.
- **AppSync merged APIs:** AWS supports merging independently managed source APIs into a single endpoint (GA since 2024). This provides an escape hatch if clients need a single URL but the backend is split.
