# Backlog: MCP Event History Resource

**Status:** Backlog
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

### Phase 1 — Event log entry types

Add `aggregateEventLogEntry` and `dcbEventLogEntry` types to `Api.res` or a new `McpEventHistory.res` module. These carry the event log name, event sury schema, and entity ID schema needed for resource registration.

### Phase 2 — Schema generator extension

Add `generateEventHistoryResources` to `MCP_SchemaGenerator`. Each entry produces:
- A single-entity resource (URI with `{entityId}` template)
- Optionally a "recent events" list resource (latest N events across all entities)

### Phase 3 — Registration hook extension

Extend `mcpSchemaRegistrationHook` params to include event log entries. Plugin_Builder passes aggregate and DCB event log specs alongside mutation/query entries.

### Phase 4 — In-memory resource handlers

Wire event history resource handlers in `MCP_Server.res`:
- Read from Bus EventLog/DcbEventLog stores
- Serialize events to JSON with type, payload, timestamp, id, sequence
- Return as `application/json` resource content

### Phase 5 — AWS resource handlers

Add DynamoDB query logic to `MCP_Lambda.res` for event history reads:
- EventLog table: query by partition key (entity ID), sort by sequence
- DcbEventLog table: query by tag, sort by sequence

### Phase 6 — Pagination

Event histories can be large. Add pagination support:
- `?limit=N` — maximum number of events to return (default: 100)
- `?after=sequenceNumber` — cursor-based pagination
- Return pagination metadata in the resource response

## Open questions

- **Event schema exposure**: Should the event type schema (variant names + payload shapes) be included as structured metadata in the resource definition? This would let agents understand what event types exist before reading history.
- **Access control**: Event history is sensitive — it may contain PII or business-critical data. Should there be a per-event-log access scope, or is the tool-level auth from Phase 9 sufficient?
- **Retention**: Should the MCP resource respect any event log retention policies, or always serve the full history?
- **DCB tag discovery**: How does an agent know which tags to filter by? Should there be a "list tags" resource alongside the event history resource?
