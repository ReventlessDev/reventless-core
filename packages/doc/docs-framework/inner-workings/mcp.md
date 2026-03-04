---
title: MCP (Model Context Protocol)
date: 2026-03-04
draft: false
---

# MCP — AI-native Access to Reventless

The MCP server layer runs alongside the GraphQL API, giving AI agents native access to the same commands and queries that drive the UI. Tools and resources are auto-generated from the same sury-typed specs that produce GraphQL schemas — no extra configuration needed.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                    Platform                          │
│                                                      │
│  ┌──────────────────┐     ┌──────────────────┐      │
│  │  GraphQL Server   │     │   MCP Server      │      │
│  │  (port 4000)      │     │   (port 3001)     │      │
│  └────────┬─────────┘     └────────┬─────────┘      │
│           │                         │                 │
│  ┌────────┴─────────────────────────┴──────────┐    │
│  │         Shared Command & Query Backend        │    │
│  │  CommandTopics (write) │ QueryDbs (read)       │    │
│  └───────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────┘
```

Both servers share:
- **Command dispatch** — MCP tools call the same mutation resolvers as GraphQL
- **Query reads** — MCP resources read from the same QueryDb stores as GraphQL queries
- **Schema generation** — both derive from `mutationSchemaEntry` / `querySchemaEntry` arrays

## MCP Concepts → Reventless Mapping

| MCP Concept | Reventless Component | Example |
|-------------|---------------------|---------|
| **Tool** | Aggregate command / StateChangeSlice command | `Catalog_CreateProduct` |
| **Resource** | ReadModel / StateViewSlice query | `catalog://products/{id}` |

### Tools (write operations)

Each command exposed via GraphQL mutations becomes an MCP Tool:

- **Name**: `PluginName_CommandName` (e.g., `Catalog_CreateProduct`)
- **Description**: from `mutationSchemaEntry.description` or auto-generated
- **Input schema**: JSON Schema derived from the command's sury `S.t<'a>` schema via `SuryToJsonSchema`

When an AI agent calls a tool, the request goes through the same command pipeline as a GraphQL mutation — identical validation, event sourcing, and side effects.

### Resources (read operations)

Each query exposed via GraphQL becomes an MCP Resource:

- **URI template**: `pluginname://resourcename/{id}` for single items, `pluginname://resourcename` for lists
- **Name**: `PluginName_ResourceName` (e.g., `Catalog_Products`)
- **MIME type**: `application/json`

## Schema Generation

The `MCP_SchemaGenerator` module converts the same entries that drive GraphQL fragment generation into MCP definitions:

```rescript
// In reventless-core/src/components/Api/MCP_SchemaGenerator.res

// Tool definitions from mutation entries
let generateTools: (
  ~pluginName: string,
  ~mutationEntries: array<mutationSchemaEntry>,
) => array<mcpToolDefinition>

// Resource definitions from query entries
let generateResources: (
  ~pluginName: string,
  ~queryEntries: array<querySchemaEntry>,
) => array<mcpResourceDefinition>
```

### Sury → JSON Schema mapping

The `SuryToJsonSchema` utility converts sury type schemas to JSON Schema objects:

| Sury type | JSON Schema |
|-----------|-------------|
| `string` | `{ "type": "string" }` |
| `float` | `{ "type": "number" }` |
| `int` / `bigint` | `{ "type": "integer" }` |
| `bool` | `{ "type": "boolean" }` |
| `@s.matches(DcbTag.string)` | `{ "type": "string", "format": "uuid" }` |
| `option<T>` | schema for T, not in `required` |
| Record | `{ "type": "object", "properties": {...}, "required": [...] }` |
| Variant `\| Cmd({fields})` | one tool per variant arm |

## Platform Integration

MCP is wired into the platform via hooks in `Plugin_Helpers`:

```rescript
// Plugin_Helpers.res — set by platform during Platform.Make()
let mcpSchemaRegistrationHook: ref<option<mcpRegistrationParams => unit>>
```

Each platform sets this hook to register MCP tools and resources during plugin construction. The hook fires after GraphQL type registration, ensuring mutation resolvers are already available for reuse.

### In-memory platform

```rescript
// In Platform.Make():
MCP_Server.start()  // starts alongside GraphQL_Server.start()
```

- Port: 3001 (default)
- Transport: Streamable HTTP via Node `http` module
- Tool handlers: reuse GraphQL mutation resolvers via `GraphQL_Server.getMutationResolver`
- Resource handlers: read from Bus QueryDb directly

### AWS platform

- Transport: Lambda Function URL with Streamable HTTP
- Tool handlers: SQS SendMessage to CommandTopic queues
- Resource handlers: DynamoDB GetItem/Query on QueryDb tables
- Auth: AWS IAM or Cognito OAuth 2.0 (configurable)

> **Note**: AWS MCP deployment requires Lambda Function URL Pulumi bindings (not yet available in `rescript-pulumi-aws`). The `MCP_Lambda` module provides deploy-time config generation and auth types as a placeholder.

## Adding Descriptions to Specs

Unlike GraphQL (where field names suffice for typed clients), MCP tools need human-readable descriptions for AI models. Add descriptions to your schema entries:

```rescript
// Good descriptions help AI agents understand when to use each tool
{
  fieldName: "createProduct",
  schema: CreateProduct.schema->S.toUnknown,
  description: "Create a new product in the catalog with a name, price, and category.",
}
```

If no description is provided, one is auto-generated from the entry name (e.g., `"Execute the createProduct command"`).

## File Map

| Package | File | Purpose |
|---------|------|---------|
| `rescript-mcp-sdk` | `src/McpSdk.res` | ReScript bindings for `@modelcontextprotocol/sdk` |
| `reventless-core` | `src/components/Api/SuryToJsonSchema.res` | Sury schema → JSON Schema conversion |
| `reventless-core` | `src/components/Api/MCP_SchemaGenerator.res` | Generate MCP tool/resource definitions |
| `reventless-core` | `src/components/Plugin/Plugin_Helpers.res` | MCP registration hook |
| `reventless-in-memory` | `src/adapter/MCP_Server.res` | In-memory MCP server (dev/test) |
| `reventless-aws` | `src/adapter/Mcp/MCP_Lambda.res` | AWS Lambda MCP adapter (placeholder) |

## Diagnostics

The in-memory `MCP_Server` provides diagnostics similar to `GraphQL_Server`:

```rescript
MCP_Server.printDiagnostics()
// [MCP Diagnostics]
//   Tools (3):
//     - Catalog_CreateProduct
//     - Catalog_ChangeProductPrice
//     - Catalog_ArchiveCategory
//   Resources (2):
//     - Catalog_Products
//     - Catalog_Categories
//   Server running: yes (port 3001)
```
