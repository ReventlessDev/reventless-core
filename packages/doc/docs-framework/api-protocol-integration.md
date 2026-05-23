# API Protocol Integration Guide

This guide explains how to add a new API protocol (e.g., OpenAPI/REST, gRPC) to the Reventless framework. It serves as a template for protocol implementors.

## Architecture

The schema generation pipeline has three layers:

```
┌─────────────────────────────────────────────────────┐
│  Plugin_Builder.construct()                         │
│  Collects mutationEntries, queryEntries,            │
│  eventLogEntries from aggregates, slices,           │
│  read models                                        │
└──────────────────────┬──────────────────────────────┘
                       │ shared entry types
                       ▼
┌─────────────────────────────────────────────────────┐
│  Protocol Generators                                │
│  GraphQL_FragmentGenerator · MCP_SchemaGenerator    │
│  (your new generator here)                          │
└──────────────────────┬──────────────────────────────┘
                       │ protocol-specific fragments
                       ▼
┌─────────────────────────────────────────────────────┐
│  Protocol Stitchers / Servers                       │
│  GraphQL_Stitcher · MCP_Server                      │
│  (your new stitcher/server here)                    │
└─────────────────────────────────────────────────────┘
```

All protocols share the same entry types and the same `SchemaType` intermediate representation. Only the bottom two layers are protocol-specific.

## Shared Infrastructure

Before writing any protocol-specific code, understand these shared modules:

### Entry Types (`reventless-infra/src/components/Api.res`)

Three entry types feed every protocol generator:

| Type | Source | Represents |
|------|--------|------------|
| `mutationSchemaEntry` | Aggregates, StateChangeSlices, InboundTranslationSlices | Write operations (commands) |
| `querySchemaEntry` | ReadModels, StateViewSlices, AutomationSlices, OutboundTranslationSlices, InboundTranslationSlices | Read operations (queries) |
| `eventLogSchemaEntry` | Aggregate EventLogs, DCB EventLogs | Event history (subscriptions, streams, feeds) |

These are protocol-agnostic. Your generator receives them as input and produces protocol-specific output.

### SchemaType (`reventless-core/src/components/Api/SchemaType.res`)

A shared intermediate representation derived from sury `S.t<unknown>` schemas:

```rescript
type rec schemaType =
  | ScalarString
  | ScalarNumber
  | ScalarBoolean
  | ScalarBigInt
  | EntityId          // @s.matches(DcbTag.string) — entity/aggregate ID
  | Nullable(schemaType)
  | ArrayOf(schemaType)
  | ObjectRef(string, dict<schemaType>)
  | Enum(string, array<string>)
  | Unknown
```

Use `SchemaType.fromSury(~parentName, ~fieldName, schema)` to convert any sury schema into this representation. Then map `schemaType` to your protocol's type system. This lets the GraphQL and MCP generators share one sury pattern-matching implementation instead of each duplicating it.

### Api_Naming (`reventless-core/src/components/Api/Api_Naming.res`)

Centralized naming functions for all protocols:

```rescript
let pluralize: string => string
let singularize: string => string
let stripViewSuffix: string => string
let toKebabCase: string => string

let aggregateMutationField: (~plugin: string, ~aggregate: string, ~command: string) => string
let sliceMutationField: (~plugin: string, ~slice: string) => string
let queryFieldNames: (~plugin: string, ~name: string) => {single: string, list: string, returnType: string}
let coreField: (~name: string) => string
```

Field names in entry types use PascalCase with underscores (e.g., `Catalog_Product_AddProduct`). If your protocol needs a different convention (e.g., kebab-case for REST paths), use `Api_Naming` to transform the canonical name. Add new transformation functions to `Api_Naming` rather than creating protocol-local helpers.

## Step-by-Step: Adding a New Protocol

### 1. Create the Fragment Generator

File: `reventless/reventless-core/src/components/Api/YourProtocol_FragmentGenerator.res`

Implement a `generate` function with this signature:

```rescript
let generate: (
  ~mutationEntries: array<ReventlessInfra.Api.mutationSchemaEntry>,
  ~queryEntries: array<ReventlessInfra.Api.querySchemaEntry>,
) => Reventless.Plugin.apiSchemaFragment
```

The returned `apiSchemaFragment` has two fields:
- `encoded: string` — JSON-serialized protocol-specific data (structure is up to you)
- `protocol: string` — a unique protocol identifier (e.g., `"openapi"`, `"grpc"`)

For each entry:
- Use `SchemaType.fromSury` to convert the sury schema
- Map `schemaType` variants to your protocol's type system
- Use `Api_Naming` for any name transformations

**Mutation entries:**
- `entry.fieldNames` contains one name per command variant (for aggregate unions) or a single name (for DCB slices)
- `entry.commandSchema` is the sury schema — `Union` for aggregate commands, `Object` for single-command slices
- For aggregate commands, inject an entity ID parameter (the aggregate instance ID)

**Query entries:**
- `entry.singleFieldName` / `entry.listFieldName` — canonical names for single-item and list operations
- `entry.returnTypeName` — the type name for the returned data
- `entry.stateSchema` — the sury schema for the state record
- `entry.excludeFields` — fields to omit from the exposed schema (optional)

**Event log entries (if your protocol supports event streams/history):**
- `entry.busKey` — internal bus key for the event log
- `entry.displayName` — human-readable name
- `entry.eventSchema` — sury schema for the event union

### 2. Create the Stitcher (if applicable)

File: `reventless/reventless-core/src/components/Api/YourProtocol_Stitcher.res`

If your protocol requires merging multiple fragments into a final schema document (like GraphQL SDL stitching or OpenAPI path merging):

```rescript
// Decode the protocol-specific JSON from a fragment
let decode: Reventless.Plugin.apiSchemaFragment => yourProtocolParts

// Encode parts back into a fragment (inverse of decode)
let encode: yourProtocolParts => Reventless.Plugin.apiSchemaFragment

// Merge base + plugin fragments into a final document
let stitch: (
  ~baseFragment: Reventless.Plugin.apiSchemaFragment,
  ~pluginFragments: array<Reventless.Plugin.apiSchemaFragment>,
) => yourFinalDocument
```

Always provide both `encode` and `decode` to avoid manual JSON construction elsewhere.

Implement collision detection — warn or error when two plugins define overlapping names.

### 3. Implement the Provider Adapter

The `Api_Adapter.Provider` module type in `reventless-infra/src/components/Api_Adapter.res` defines the interface that platform adapters implement:

```rescript
module type Provider = {
  type api
  type role
  let makeApiResource: (~name: string, ~opts: Pulumi.ComponentResource.options) => (Output.t<api>, Output.t<role>)
  let generateFragment: (~mutationEntries: ..., ~queryEntries: ...) => apiSchemaFragment
  let updateSchema: (~api: Output.t<api>, ~baseFragment: ..., ~pluginFragments: ...) => promise<unit>
}
```

Create two implementations:

**AWS adapter** (`reventless-aws/src/components/Api/YourProtocol_Adapter.res`):
- `makeApiResource` — provision the cloud resource (e.g., API Gateway REST API)
- `generateFragment` — delegate to your fragment generator
- `updateSchema` — stitch fragments and deploy the schema to the cloud resource

**In-memory adapter** (`reventless-in-memory/src/adapter/Api/YourProtocol_InMemory_Adapter.res`):
- `makeApiResource` — create a local server instance
- `generateFragment` — delegate to your fragment generator
- `updateSchema` — register routes/handlers on the local server

### 4. Register with the Platform

Registration happens in `Plugin_Builder.construct()` via callbacks passed as parameters. Your platform adapter provides these callbacks when constructing plugins.

For the in-memory platform (`reventless-in-memory/src/Platform.res`):
- Pass your registration callback through the platform's construction flow
- The callback receives the shared entry types and can call your generator to register routes/tools/resources

For the AWS platform:
- `generateFragment` is called at deploy time via the `Api_Adapter.Provider`
- `updateSchema` is called at runtime when plugins connect/disconnect

### 5. Handle Core Operations

Core operations (Plugin CRUD, Clone) generate their own entries. Ensure your protocol picks them up — they flow through the same `FragmentProvider.generateFragment` path as plugin entries.

## Naming Conventions by Protocol

| Source | GraphQL / MCP | REST (OpenAPI) |
|--------|---------------|----------------|
| Aggregate mutation | `Plugin_Aggregate_Command` | `POST /plugin/aggregate/command` |
| DCB slice mutation | `Plugin_SliceName` | `POST /plugin/slice-name` |
| Query (single) | `Plugin_EntityName` | `GET /plugin/entity-name/{id}` |
| Query (list) | `Plugin_EntityNames` | `GET /plugin/entity-names` |
| Core mutation | `Core_Plugin_Activate` | `POST /core/plugin/activate` |
| Core query | `Core_Plugin` | `GET /core/plugin/{id}` |
| Event history | MCP resource template | `GET /plugin/entity-events/{id}` |

GraphQL and MCP use the canonical `fieldNames` from entries directly. REST protocols should apply `Api_Naming.toKebabCase` to each segment.

## Checklist

- [ ] Fragment generator in `reventless-core/src/components/Api/`
- [ ] Uses `SchemaType.fromSury` (not raw sury pattern matching)
- [ ] Uses `Api_Naming` for name transforms (not local helpers)
- [ ] Stitcher with `encode`/`decode` (if protocol merges fragments)
- [ ] Collision detection in stitcher
- [ ] AWS adapter in `reventless-aws/src/components/Api/`
- [ ] In-memory adapter in `reventless-in-memory/src/adapter/Api/`
- [ ] Registration via explicit callbacks (not global mutable hooks)
- [ ] Core operations included (Plugin CRUD, Clone)
- [ ] Event log entries handled (if protocol supports history/subscriptions)
- [ ] Tests for generator, stitcher, and naming
- [ ] Update `eventLogSchemaEntry` TSDoc if adding a new consumption pattern
