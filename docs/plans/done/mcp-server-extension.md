# Plan: MCP Server Extension — AI-native Access to Reventless

**Status:** Complete
**Analysis:** `docs/analysis/mcp-server-extension.md`
**Branch:** alpha

## Goal

Add an MCP (Model Context Protocol) server layer alongside the existing GraphQL API so that AI agents can natively discover and interact with a Reventless-based business platform. The MCP server auto-generates tool and resource definitions from the same sury-typed specs that already drive GraphQL generation.

Two stages:
- **Stage 1 — Read-only (Resources only):** ReadModels and StateViewSlices exposed as MCP Resources. No mutations, low risk.
- **Stage 2 — Full (Resources + Tools):** Aggregate commands and DCB StateChangeSlice commands exposed as MCP Tools. Requires auth.

Two concrete providers:
- **In-memory** (`reventless-in-memory`) — local dev and testing; Streamable HTTP via Node `http` module.
- **AWS** (`reventless-aws`) — production; Lambda Function URL with Streamable HTTP transport.

## Key design decisions

- **One platform-wide MCP server** (Option B from analysis) — all plugins' tools and resources are namespaced by plugin name in a single server. Fits the existing `makePlatform` aggregation pattern.
- **`@modelcontextprotocol/sdk`** (TypeScript SDK) handles protocol framing, schema validation, and transport. Reventless compiles to JS, so the SDK integrates directly.
- **Transport: Streamable HTTP** — the MCP 2025-03-26 spec's recommended production transport. SSE-based transport is deprecated.
- **Schema derivation reuses `GraphQL_SchemaInspector` patterns** — the sury `S.t<'a>` traversal in `GraphQL_FragmentGenerator` (scalar mapping, object type derivation) is the same conceptual operation needed for MCP JSON Schema generation. A shared `SchemaInspector` utility will serve both.
- **Naming conventions follow GraphQL** — `PluginName_AggregateName_CommandName` for tools, `PluginName_ReadModelName` for resources. Same rules, different protocol.
- **`pluginDefinition` is not extended** — MCP schemas are derived at server startup from the same `mutationSchemaEntry` / `querySchemaEntry` arrays that drive GraphQL fragment generation. No new per-plugin build artifact needed.
- **Descriptions are required for MCP** — unlike GraphQL (where field names suffice for typed clients), MCP tools need human-readable `description` fields for AI models. This plan introduces an optional `description` field on `mutationSchemaEntry` and `querySchemaEntry`.

## Dependencies

- The `Api` component infrastructure (Phases 1–10 of `api-component-graphql` plan) must be complete — specifically `mutationSchemaEntry`, `querySchemaEntry`, and `Plugin_Builder` fragment generation.
- `@modelcontextprotocol/sdk` npm package must be added as a dependency.

## Steps

### Phase 1 — Add `@modelcontextprotocol/sdk` dependency and ReScript bindings

**Package:** `rescript/rescript-mcp-sdk/` (new binding package)

- Create a new ReScript binding package for `@modelcontextprotocol/sdk`.
- Bind the core types: `Server`, `McpServer`, `Tool`, `Resource`, `ResourceTemplate`, transport types (`StreamableHTTPServerTransport`).
- Bind `McpServer.tool()`, `McpServer.resource()`, `McpServer.connect()`.
- Bind the Zod-like schema input format that the SDK uses for tool `inputSchema` (or pass raw JSON Schema objects — the SDK accepts both).
- Add `rescript-mcp-sdk` to root `rescript.json` dependencies so it compiles to ESM from root.

**Tests:** Smoke test that imports the SDK and creates a server instance.

### Phase 2 — `MCP_SchemaGenerator` in `reventless-core`

**File:** `reventless/reventless-core/src/components/Api/MCP_SchemaGenerator.res`

Extract and generalize the sury `S.t<'a>` → JSON Schema traversal from `GraphQL_FragmentGenerator`:

```rescript
// Converts a sury schema to a JSON Schema object (for MCP tool inputSchema)
let toJsonSchema: S.t<'a> => JSON.t

// Generates MCP tool definitions from mutation entries
let generateTools: (
  ~pluginName: string,
  ~mutationEntries: array<mutationSchemaEntry>,
) => array<mcpToolDefinition>

// Generates MCP resource definitions from query entries
let generateResources: (
  ~pluginName: string,
  ~queryEntries: array<querySchemaEntry>,
) => array<mcpResourceDefinition>
```

Types:
```rescript
type mcpToolDefinition = {
  name: string,               // "Catalog_CreateProduct"
  description: string,        // from mutationSchemaEntry.description or auto-generated
  inputSchema: JSON.t,        // JSON Schema object derived from command sury schema
}

type mcpResourceDefinition = {
  uriTemplate: string,        // "catalog/products" or "catalog/product/{id}"
  name: string,               // "Catalog_Product"
  description: string,
  mimeType: string,           // "application/json"
}
```

Sury → JSON Schema mapping:
- `string` → `{ "type": "string" }`
- `float` → `{ "type": "number" }`
- `int` → `{ "type": "integer" }`
- `bool` → `{ "type": "boolean" }`
- `@s.matches(DcbTag.string)` → `{ "type": "string", "format": "uuid" }` (entity ID)
- `option<T>` → schema for T without `required`
- Record → `{ "type": "object", "properties": {...}, "required": [...] }`
- Variant `| CmdName({fields...})` → one tool per variant arm

**Tests:** Full coverage — scalar types, nested objects, optional fields, variant commands, DcbTag IDs.

### Phase 3 — Add `description` to schema entry types

**Files:**
- `reventless/reventless-infra/src/components/Api.res`
- `reventless/reventless-core/src/components/Plugin/Plugin_Builder.res`

Extend:
```rescript
type mutationSchemaEntry = {
  ...existing fields,
  description?: string,  // optional — used by MCP, ignored by GraphQL
}

type querySchemaEntry = {
  ...existing fields,
  description?: string,
}
```

Update `Plugin_Builder` to pass through descriptions from specs. For MCP, auto-generate a default description from the entry name if none is provided (e.g., `"Execute the CreateProduct command on the Catalog plugin"`).

Backward-compatible — existing code that omits `description` continues to work.

**Tests:** Verify descriptions flow through Plugin_Builder to fragment generation.

### Phase 4 — `Mcp_Adapter.res` in `reventless-infra`

**File:** `reventless/reventless-infra/src/components/Mcp_Adapter.res`

Define the adapter interface (parallel to `Api_Adapter.res`):

```rescript
module type Provider = {
  type server

  // Create the MCP server runtime
  let makeServer: (~name: string) => server

  // Register tools and resources from plugin entries
  let registerPlugin: (
    server,
    ~pluginName: string,
    ~mutationEntries: array<mutationSchemaEntry>,
    ~queryEntries: array<querySchemaEntry>,
    ~commandHandler: (string, JSON.t) => promise<JSON.t>,
    ~queryHandler: (string, JSON.t) => promise<JSON.t>,
  ) => unit

  // Start serving (transport-specific)
  let start: (server, ~port: int) => promise<unit>

  // Stop serving
  let stop: server => promise<unit>
}
```

### Phase 5 — In-memory MCP adapter (Stage 1 — Resources only)

**Files:**
- `reventless/reventless-in-memory/src/adapter/MCP_Server.res` (new — parallel to `GraphQL_Server.res`)
- `reventless/reventless-in-memory/src/adapter/Mcp/McpResourceResolvers_InMemory.res` (new)

`MCP_Server.res`:
- Implements `Mcp_Adapter.Provider` using `@modelcontextprotocol/sdk`.
- Creates a `McpServer` with Streamable HTTP transport on a configurable port (default 3001).
- Registry pattern matching `GraphQL_Server.res` — `registerResources`, `reset`, `start`, `stop`.
- Resources only in Stage 1: `server.resource()` calls for each `querySchemaEntry`.

`McpResourceResolvers_InMemory.res`:
- Converts `querySchemaEntry` + QueryDb lookup into MCP resource handlers.
- Single-item resources: `read(uri)` → QueryDb get → JSON response.
- List resources: `read(uri)` → QueryDb scan → JSON array response.

Wire into `Platform.Make()`:
- After `GraphQL_Server.start()`, also call `MCP_Server.start()` inside `makePlatform`.
- Plugin connect hook registers MCP resources alongside GraphQL fragments.

**Tests:**
- Unit tests for resource registration and resolution.
- Integration test: create a ReadModel via in-memory platform, start MCP server, use SDK client to list resources and read a resource.

### Phase 6 — In-memory MCP adapter (Stage 2 — Add Tools)

**Files:**
- `reventless/reventless-in-memory/src/adapter/Mcp/McpToolResolvers_InMemory.res` (new)

`McpToolResolvers_InMemory.res`:
- Converts `mutationSchemaEntry` + CommandTopic dispatch into MCP tool handlers.
- Each tool: `call(args)` → validate args against sury schema → dispatch command to CommandTopic → return result.
- Tool execution goes through the same command pipeline as GraphQL mutations — same validation, same event sourcing.

Wire into `MCP_Server.res`:
- Add `registerTools` alongside `registerResources`.
- Plugin connect hook registers both.

**Tests:**
- Unit tests for tool registration and argument validation.
- Integration test: create an Aggregate via in-memory platform, start MCP server, use SDK client to list tools, call a tool, verify event was produced.
- E2E test: full round-trip — call MCP tool (command) → event sourced → read MCP resource (read model) → verify projected state.

### Phase 7 — Wire MCP into `Platform.T`

**File:** `reventless/reventless-infra/src/types/Platform.res`

Add optional `Mcp` module to `Platform.T`:

```rescript
module type T = {
  ...existing modules...

  module Mcp: {
    module Make: (Config: {let serverName: string, let port: int}) => Mcp_Adapter.Provider
  }
}
```

Update `makePlatform` signature to accept optional MCP config:

```rescript
let makePlatform: (
  ~api: Api.T,
  ~mcp: Mcp.T=?,  // optional — platform works without MCP
  ~core: Core.T,
  ~plugins: array<Plugin.T>,
) => unit
```

The in-memory `Platform.Make()` provides a concrete `Mcp` module using `MCP_Server`. AWS `Platform` will provide its own in Phase 8.

### Phase 8 — AWS MCP adapter (Lambda Function URL)

**Files:**
- `reventless/reventless-aws/src/adapter/Mcp/MCP_Lambda.res` (new)

Implements `Mcp_Adapter.Provider` for AWS:
- `makeServer`: creates a Lambda Function URL resource (Pulumi) with Streamable HTTP routing.
- Tool/resource registration happens at deploy time — generates the MCP server handler code.
- Lambda handler: on each HTTP request, parses MCP protocol, routes to tool/resource handlers.
- Tool handlers dispatch to SQS CommandTopics (same as AppSync resolver Lambda).
- Resource handlers read from DynamoDB QueryDbs (same as AppSync resolver Lambda).

Deploy-time artifacts:
- Lambda function with `@modelcontextprotocol/sdk` bundled.
- Function URL (public or IAM-authenticated).
- IAM role with permissions for SQS SendMessage + DynamoDB GetItem/Query.

### Phase 9 — Auth and rate limiting (AWS)

**Files:**
- Extend `MCP_Lambda.res` with auth configuration.

- **OAuth 2.0 / Cognito**: MCP 1.0 standardizes on OAuth 2.0. Reuse the same Cognito User Pool as AppSync. The Lambda Function URL validates JWT tokens from the `Authorization` header.
- **Scoped tool access**: configurable per-tool authorization — tools can be marked as requiring specific Cognito groups or OAuth scopes.
- **Rate limiting**: API Gateway throttling settings or Lambda reserved concurrency as a coarse rate limiter.
- **Read-only mode**: a deployment flag that registers only Resources (no Tools) for conservative initial rollout.

### Phase 10 — Examples and documentation

- Add MCP section to `packages/doc/docs/reventless-components/api.md`.
- Document the MCP naming conventions (parallel to GraphQL conventions).
- Add description-writing guidance for specs (how to write good tool descriptions for AI agents).
- Add example: extend `examples/dcb/` with MCP server alongside GraphQL.
- Document the `makePlatform(~mcp=...)` configuration.

## Files changed summary

| Package | File | Change type |
|---------|------|-------------|
| `rescript-mcp-sdk` | `rescript/rescript-mcp-sdk/` (entire package) | New |
| `reventless-infra` | `src/components/Api.res` | Modified (add `description` to entry types) |
| `reventless-infra` | `src/components/Mcp_Adapter.res` | New |
| `reventless-infra` | `src/types/Platform.res` | Modified (add optional `Mcp` module) |
| `reventless-core` | `src/components/Api/MCP_SchemaGenerator.res` | New |
| `reventless-core` | `src/components/Plugin/Plugin_Builder.res` | Modified (pass descriptions) |
| `reventless-in-memory` | `src/adapter/MCP_Server.res` | New |
| `reventless-in-memory` | `src/adapter/Mcp/McpResourceResolvers_InMemory.res` | New |
| `reventless-in-memory` | `src/adapter/Mcp/McpToolResolvers_InMemory.res` | New |
| `reventless-in-memory` | `src/Platform.res` | Modified (wire MCP into `makePlatform`) |
| `reventless-aws` | `src/adapter/Mcp/MCP_Lambda.res` | New |

## Open questions

- **sury `S.t<'a>` → JSON Schema traversal**: The existing `GraphQL_FragmentGenerator` does this for GraphQL SDL. Should this be extracted into a shared `SuryToJsonSchema` utility in `reventless-core`, or kept as a separate implementation in `MCP_SchemaGenerator`? A shared utility is cleaner but couples GraphQL and MCP generation.
- **MCP server port in tests**: The in-memory MCP server needs a port. Should it share `GraphQL_Server`'s lifecycle (start/stop together) or be independently controllable? Independent is more flexible but adds test setup complexity.
- **Tool descriptions from type names**: Auto-generating descriptions like `"Execute CreateProduct on Catalog"` is better than nothing but may not be good enough for AI agents. Should the plan include a `@mcp.description("...")` PPX annotation on command variants? This is a larger change to sury-ppx.
- **Event history as a resource**: The analysis suggests exposing EventLog as an MCP Resource. This is powerful but requires careful schema design. Defer to a follow-up plan or include here?
- **Versioning**: MCP tool schemas should be stable. Breaking changes to command types break agents. What versioning strategy? Suffix-based (`_v2`) or MCP protocol-level versioning?
