---
title: DcbEventLog
sidebar_position: 13
---

# DcbEventLog — Local

**Source:** `reventless-local/src/adapter/DcbEventLog/DcbEventLogStorage_InMemory.res`

## Data Structure

Events are stored in a `ref<array<rawSequencedEvent>>`. A monotonically increasing `ref<int>` position counter assigns a unique position to each appended event.

## Operations

| Operation | Description |
|-----------|-------------|
| `read` | Returns events matching a tag-based query, optionally filtering by position (`~after`) |
| `append` | Appends events with conflict detection via `appendCondition` |
| `readStream` | Stream variant of `read` |

## Tag-Based Query Matching

The `matchesQuery` function implements the same logic as the DynamoDB adapter:
- An empty query matches all events
- Each query item can filter by `eventTypes` and/or `tags`
- A query item matches if **all** its tag constraints match (AND) and the event type is in the allowed list
- Multiple query items are combined with OR — an event matches if **any** query item matches

## Conflict Detection

The `append` function supports optimistic concurrency via `appendCondition`:
- Checks if any existing event after the `condition.after` position matches the condition's query
- Returns `Error("conflict: condition check failed")` if a conflict is detected
- Returns `Ok(position)` on success

## Bus Integration

When created via `Make(Bus)`, the adapter registers its `read` function on the bus so that MCP resources and other components can look up DCB event history.

## Key Differences from AWS

| Aspect | Local | AWS |
|--------|----------|-----|
| Storage | In-memory array | DynamoDB table with tag-based indexes |
| Position | Incrementing integer counter | DynamoDB auto-generated position |
| Query | In-memory array filter | DynamoDB query with tag conditions |
| Conflict detection | Array scan after position | DynamoDB conditional write |
