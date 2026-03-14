# Analysis: Splitting GraphQL API and MCP Server into Core vs Plugin Schemas

## Context

The current Reventless API layer (GraphQL + MCP) merges all schema definitions — core administrative types and plugin-contributed business domain types — into a single unified endpoint. This analysis evaluates splitting both the GraphQL API and MCP server into two distinct parts:

1. **Core endpoint** — administrative queries/mutations (plugin management, platform introspection)
2. **Plugin endpoint** — all business domain queries/mutations contributed by plugins

## Current Architecture

### GraphQL Schema Composition

The GraphQL schema is built from two sources:

1. **Base fragment** (`CoreApi.baseFragment`) — Core administrative schema:
   - Types: `Core_Plugin`, `Core_Plugins` (wrapper)
   - Queries: `Core_Plugin(id: ID!)`, `Core_Plugins(nextToken, limit)`
   - Mutations: `Core_Plugin_Activate(id: ID!)`, `Core_Plugin_Deactivate(id: ID!)`, `Core_Clone(id: ID!)`

2. **Plugin fragments** — each plugin generates its own fragment during `Plugin_Builder.construct()`:
   - Aggregate command mutations: `${plugin}_${aggregate}_${command}(id: ID!, ...args)`
   - ReadModel queries: `${plugin}_${name}(id: ID!)`, `${plugin}_${names}(nextToken, limit)`
   - StateChangeSlice mutations: `${plugin}_${slice}(...args)`
   - StateViewSlice queries: same pattern as ReadModel

These are merged by `GraphQL_Stitcher.stitch(~baseFragment, ~pluginFragments)` into a single SDL string, which is then served by either AppSync (AWS) or graphql-yoga (in-memory).

### MCP Server Composition

The MCP server follows the same pattern — a single server exposes both core and plugin tools/resources:

- **Core tools**: `Core_Plugin_Activate`, `Core_Plugin_Deactivate`, `Core_Clone`
- **Core resources**: `Core/Core_Plugin/{id}`, `Core/Core_Plugins`
- **Plugin tools**: one per aggregate command variant or StateChangeSlice command
- **Plugin resources**: one per ReadModel/StateViewSlice (single + list), plus event history resources

All are registered into the shared `MCP_Server` registry and served from a single HTTP endpoint (port 3001).

### Schema Flow Diagram

```
Plugin_Builder.construct()
  ├── mutationEntries (from aggregates + DCB slices)
  ├── queryEntries (from ReadModels + StateViewSlices)
  └── eventLogEntries (from EventLogs)
        │
        ├──→ FragmentProvider.generateFragment() → apiSchemaFragment (GraphQL SDL)
        ├──→ schemaTypeRegistrationHook → GraphQL_Server.registerTypes()
        ├──→ aggregateMutationResolverHook → GraphQL_Server.registerMutations()
        └──→ mcpSchemaRegistrationHook → MCP_Server.registerToolsFromEntries()
                                        → MCP_Server.registerResourcesFromEntries()
                                        → MCP_Server.registerEventHistoryResourcesFromEntries()

makePlatform()
  ├── CoreApi.baseFragment → GraphQL_Server (types, queries, mutations)
  ├── Core MCP tools/resources → MCP_Server
  ├── GraphQL_Server.start() → port 4000
  └── MCP_Server.start() → port 3001
```

## Proposed Split

### Option A: Two Separate Endpoints

**GraphQL:**
- `POST /graphql/core` — Core administrative schema only
- `POST /graphql` — Plugin business domain schema only (or combined)

**MCP:**
- `POST /mcp/core` — Core tools and resources
- `POST /mcp` — Plugin tools and resources

### Option B: Two Separate Server Instances

**GraphQL:**
- Port 4000 — Plugin business domain (primary API)
- Port 4001 — Core administrative API

**MCP:**
- Port 3001 — Plugin MCP server
- Port 3002 — Core MCP server

### Option C: Single Endpoint with Namespace Separation (Schema-Only Split)

Keep a single endpoint but clearly separate the schema generation and registration so that core and plugin schemas are independently composable. The stitcher would be configured to include/exclude the base fragment.

## Feasibility: GraphQL Split

### What needs to change

**Low effort — the architecture already supports this.** The key insight: `GraphQL_Stitcher.stitch()` already takes `~baseFragment` and `~pluginFragments` as separate inputs. Creating two schemas is straightforward:

1. **Core-only schema**: Call `stitch(~baseFragment=CoreApi.baseFragment, ~pluginFragments=[])` — produces a schema with only Core types/queries/mutations.

2. **Plugin-only schema**: Call `stitch(~baseFragment=emptyFragment, ~pluginFragments=allPluginFragments)` — produces a schema with only plugin-contributed types/queries/mutations.

**In-memory platform changes:**
- `GraphQL_Server.res` currently uses a single registry. Would need either:
  - Two `GraphQL_Server` instances (cleanest), or
  - A namespace parameter to partition registrations and build two separate yoga instances

**AWS platform changes:**
- Create two AppSync APIs instead of one (each with its own schema)
- Or use AppSync's merged APIs feature (GA since 2024) to compose two source APIs
- Lambda handlers already route by field name, so resolver separation is natural

**Resolver separation is already clean:** Core resolvers (Plugin_Activate, Plugin_Deactivate, Clone, Plugin queries) are registered separately in `makePlatform()`. Plugin resolvers are registered via hooks during `Plugin_Builder.construct()`. No interleaving.

### Breaking changes

- Clients currently making requests to a single endpoint would need to know which endpoint to hit
- If a client needs both core and plugin data in a single request (e.g., listing plugins alongside business data), this would require two round-trips

## Feasibility: MCP Split

### What needs to change

**Also low effort — the MCP server uses the same pattern.** The `MCP_Server.res` module uses dictionaries (`tools`, `resources`, `resourceTemplates`) that can be trivially partitioned:

1. **Core MCP server**: Register only `Core_*` tools and resources. Serve on `/mcp/core`.
2. **Plugin MCP server**: Register only plugin tools and resources. Serve on `/mcp`.

**Implementation approaches:**

**Approach 1 — Two `MCP_Server` instances:**
- Duplicate the module (or parameterize it) to create `MCP_Server_Core` and `MCP_Server_Plugin`
- Each has its own registry and HTTP server
- Clean separation, no shared state

**Approach 2 — Single server with path-based routing:**
- `POST /mcp/core` → routes to core tool/resource handlers
- `POST /mcp` → routes to plugin tool/resource handlers
- Single HTTP server, two logical MCP server instances (one per path)

**Approach 3 — Two MCP server configs (AWS Lambda):**
- Two Lambda Function URLs, each with its own MCP config
- `MCP_Lambda.generateConfig()` already receives plugin-specific entries — just need a separate invocation for core entries

### MCP-specific considerations

- MCP clients (AI agents) typically connect to a single server URL. Splitting means the agent needs two server configurations, which adds friction.
- However, MCP supports server discovery and multi-server configurations in most clients (Claude Desktop, VS Code, etc.)
- For AI agents interacting with the platform, having the business domain separate from administrative operations is a natural security boundary

## Consequences

### Advantages of Splitting

1. **Security boundary**: Core administrative operations (activate/deactivate plugins, clone) can have different authentication/authorization than business domain operations. In AWS, this maps to separate Cognito groups or IAM policies per AppSync API.

2. **Independent scaling**: The core API handles low-frequency administrative traffic. The plugin API handles high-frequency business operations. Separate endpoints allow independent scaling and rate limiting.

3. **Schema clarity**: Business domain users see only their domain types — no `Core_Plugin_Activate` pollution in their schema introspection. AI agents see only relevant tools, reducing confusion and improving tool selection.

4. **Independent evolution**: Core schema changes (new admin features) don't require re-deployment of plugin schemas, and vice versa. Version management is simpler.

5. **Smaller attack surface**: Administrative endpoints can be restricted to internal networks or specific IP ranges, while business endpoints are exposed to external clients.

6. **Better MCP agent experience**: An AI agent working with business data doesn't need to see or be tempted by `Core_Plugin_Activate`. Tool lists stay focused and relevant.

7. **AppSync merged API compatibility**: AWS AppSync's merged APIs feature is designed exactly for this pattern — compose independently managed source APIs into a single merged endpoint when needed.

### Disadvantages of Splitting

1. **Two endpoints to manage**: Clients need to know which endpoint to use. Configuration becomes more complex (two URLs, two auth configs).

2. **Cross-domain queries require two round-trips**: If a client wants to show plugin status alongside business data (e.g., a dashboard showing "Catalog plugin: active" next to product listings), it needs two GraphQL requests.

3. **MCP multi-server friction**: AI agents need two MCP server configurations. While supported, this adds setup complexity and the agent must decide which server to query.

4. **Deployment complexity**: Two AppSync APIs, two Lambda Function URLs, two sets of CloudWatch dashboards. Infrastructure cost doubles for the API layer (though the backing resources remain shared).

5. **Schema type sharing**: If plugins ever need to reference core types (e.g., `Core_Plugin` in a plugin query response), the types would need to be duplicated or a shared types fragment introduced.

6. **CORS / network configuration**: Two origins to allowlist, two TLS certificates to manage (if on different domains).

## Mitigation: Hybrid Approach

The disadvantages can be mitigated with a **hybrid approach**:

- **Generate schemas separately** (core vs plugin) — this is the architectural split
- **Serve from a single endpoint by default** — stitch both schemas together as today
- **Optionally serve separately** — provide a platform configuration flag to split into two endpoints when the security/scaling benefits are needed

This requires minimal changes:
1. Refactor `makePlatform()` to generate core and plugin schemas independently (already almost the case)
2. Add a `splitApi?: bool` platform config option
3. When `splitApi=true`: start two graphql-yoga instances / create two AppSync APIs
4. When `splitApi=false` (default): stitch and serve as today

For MCP, the same pattern applies — a `splitMcp?: bool` flag that controls whether core and plugin tools/resources are served from one or two server instances.

## Implementation Estimate

### Phase 1: Schema generation separation (foundation)
- Extract core schema generation into a standalone function (already exists as `CoreApi.baseFragment`)
- Ensure plugin schema generation produces a valid standalone schema (verify `_noop` fallback in stitcher handles missing mutations/queries)
- No behavioral change — preparation only

### Phase 2: In-memory platform split
- Parameterize `GraphQL_Server` to support named instances (or create two instances)
- Parameterize `MCP_Server` similarly
- Add platform config flag (`splitApi`, `splitMcp`)
- Update `makePlatform()` to conditionally start one or two server pairs

### Phase 3: AWS platform split
- Parameterize `AppSync_Adapter` to create one or two APIs
- Update `MCP_Lambda` to generate one or two Lambda configs
- Update Pulumi stack outputs for the split case

### Phase 4: Documentation and migration
- Update the platform-and-plugin guide
- Document the split configuration option
- Provide migration guide for existing clients

## Recommendation

**Implement the hybrid approach.** The architecture already cleanly separates core and plugin schema generation. The split is a matter of plumbing — routing schemas to one vs two server instances. The default should remain unified (single endpoint) for simplicity, with an opt-in split for production deployments that benefit from the security/scaling separation.

The MCP split is particularly valuable for AI agent use cases: an agent working with business data should not see administrative tools, and an operations agent managing the platform should not be distracted by hundreds of domain-specific tools.

Start with Phase 1 (no behavioral change, just structural preparation) and Phase 2 (in-memory platform, testable locally). Defer Phase 3 (AWS) until a concrete production need arises.
