# MCP Event History Resource

**Status:** All phases completed (1–6)
**Depends on:** MCP Server Extension plan (completed — `docs/plans/mcp-server-extension.md`)
**Related:** `docs/analysis/mcp-server-extension.md` (section 5: Event history as agent context)

## Motivation

The MCP server extension (Phases 1–10) exposes commands as Tools and read-model queries as Resources. However, one powerful capability is missing: **event history as a Resource**.

An AI agent deciding whether to create a product, modify a price, or cancel an order benefits enormously from reading the entity's event history first. The EventLog (per-aggregate, append-only) and DcbEventLog (per-DCB, multi-entity) are natural fits for MCP Resources — agents read historical context to make informed decisions.

This is exactly what MCP Resources are designed for: structured, read-only data retrieval that provides context for tool invocations.

## Design

### Resource types

Two categories of event history resources:

1. **Aggregate EventLog** — per-entity event stream
   - URI: `pluginname://aggregatename/events/{entityId}`
   - Returns: ordered array of events for a single entity
   - Example: `catalog://product/events/prod-123` → all events for product `prod-123`

2. **DCB EventLog** — multi-entity event log with tag-based filtering
   - URI: `pluginname://eventlog/{logName}/events?tag={tagValue}`
   - Returns: filtered array of events matching the DCB tag
   - Example: `catalog://eventlog/catalog/events?tag=prod-123` → all catalog events tagged with `prod-123`

### Event serialization

Events need human-readable serialization for AI consumption:

- Each event in the response array includes:
  - `type` — the event variant name (e.g., `"ProductCreated"`)
  - `payload` — the event data as JSON (sury-encoded)
  - `timestamp` — when the event was recorded
  - `id` — the entity/aggregate ID
  - `sequence` — position in the stream (for ordering)

### Schema generation

Extend `MCP_SchemaGenerator` with:

```rescript
let generateEventHistoryResources: (
  ~pluginName: string,
  ~aggregateEntries: array<aggregateEventLogEntry>,  // new type
  ~dcbEventLogEntries: array<dcbEventLogEntry>,       // new type
) => array<mcpResourceDefinition>
```

### In-memory implementation

- Aggregate EventLog: read from in-memory EventLog storage via `Bus.getEventLog(name)`
- DCB EventLog: read from `Bus.getDcbEventLog(name)` with tag-based filtering
- Both return JSON arrays of serialized events

### AWS implementation

- Aggregate EventLog: DynamoDB Query on the EventLog table, partitioned by entity ID
- DCB EventLog: DynamoDB Query with tag-based key conditions
- Lambda handler reads from the same DynamoDB tables as the event-sourcing runtime

## Steps

### Phase 1 — Event log entry types ✅

Added `eventLogSchemaEntry` type to `Api.res` with `busKey`, `displayName`, and `eventSchema` fields.

### Phase 2 — Schema generator extension ✅

Added `generateEventHistoryResources` to `MCP_SchemaGenerator`. Each entry produces a single-entity event history resource with URI template `{pluginName}/{displayName}_events/{entityId}`.

### Phase 3 — Registration hook extension ✅

Extended `mcpRegistrationParams` with `eventLogEntries`. Plugin_Builder collects entries from aggregates (busKey = `SpecName + "Aggr" + "EventLog"`) and DCB (busKey = `pluginName + "DcbEventLog"`).

### Phase 4 — In-memory resource handlers ✅

Wired event history resource handlers in Platform.res and MCP_Server.res:
- Added `registerEventLogReplay`/`getDcbEventLogRead` registries to InMemory_Bus
- Added `Make(Bus)` functors to EventLogStorage_InMemory and DcbEventLogStorage_InMemory
- Updated Aggregate_Builder and Plugin_Builder to use Make(Bus) variants
- MCP handler reads from Bus registries, serializes events to JSON

### Bug fixes discovered during integration testing ✅

Several issues found and fixed when testing MCP with the online-shop-aggregates example:

1. **QueryDb naming mismatch** — `QueryDb_Builder.res` passed a suffixed name (`name + "QueryDB"`) to Storage but the base `name` to Resolvers, causing Bus lookup mismatches. Both GraphQL and MCP queries returned empty/null. Fixed by passing base `name` to Storage (removing the redundant suffix).

2. **MCP list resource lookup failure** — Platform.res MCP query handler only matched `singleFieldName` in the `queryFieldNamesRegistry`, missing list resources (e.g., `Catalog_Categories`). Fixed by also checking `entry.listFieldName == Some(resourceName)`.

3. **MCP resource templates** — Event history resources (and single-item query resources) have parameterized URIs with `{entityId}` or `{id}`, but were all registered as regular MCP resources. MCP clients (e.g., MCP Inspector) couldn't handle template-style URIs in regular resources. Fixed by:
   - Adding `resourceTemplates` registry to MCP_Server alongside `resources`
   - Splitting in `registerResourcesFromEntries`: URIs with `{` → templates, fixed URIs → regular resources
   - `registerEventHistoryResourcesFromEntries` always registers as templates
   - Added `onListResourceTemplates` handler in `createServerInstance`
   - Updated `onReadResource` to search both registries (regular first, then templates)

### Phase 5 — AWS resource handlers ✅

Extended `MCP_Lambda.res` with event history support:
- Added `mcpEventHistoryEntry` type and `eventHistoryResources` field to `mcpConfig`
- Extended `generateConfig` to accept `~eventLogEntries` and `~eventLogTableNames` (with defaults for backward compatibility)
- Added `readEventLogHistory` — queries EventLog DynamoDB table using `queryStream` with `exclusiveStartKey` for cursor-based pagination and `Stream.take` for efficient limiting
- Added `readDcbEventLogHistory` — reads DcbEventLog DynamoDB table using existing runtime `read` function with tag-based entity filtering
- Added shared URI parsing helpers: `extractEntityId`, `parsePaginationParams`, `paginatedResponse`
- Updated IAM role documentation to include EventLog and DcbEventLog table permissions

### Phase 6 — Pagination ✅

Added pagination support to both in-memory and AWS event history handlers:
- `?limit=N` — maximum number of events to return
- `?after=position` — cursor-based pagination (sequenceNr for EventLog, position for DcbEventLog)
- Response format changed from flat array to `{events: [...], pagination: {hasMore, nextAfter}}`
- In-memory (Platform.res): parses URI query params, applies after-filtering and limit with a shared `paginate` helper
- AWS (MCP_Lambda.res): uses DynamoDB `exclusiveStartKey` for native cursor pagination on EventLog; applies limit after read for DcbEventLog
- Both platforms use the same response format via `paginatedResponse` / `makePaginatedResponse` helpers

## Open questions

- **Event schema exposure**: Should the event type schema (variant names + payload shapes) be included as structured metadata in the resource definition? This would let agents understand what event types exist before reading history.
- **Access control**: Event history is sensitive — it may contain PII or business-critical data. Should there be a per-event-log access scope, or is the tool-level auth from Phase 9 sufficient?
- **Retention**: Should the MCP resource respect any event log retention policies, or always serve the full history?
- **DCB tag discovery**: How does an agent know which tags to filter by? Should there be a "list tags" resource alongside the event history resource?
