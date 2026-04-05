---
title: EventLog
sidebar_position: 1
---

# EventLog — InMemory

**Source:** `reventless-in-memory/src/adapter/EventLog/EventLogStorage_InMemory.res`

**AWS equivalent:** [EventLog → DynamoDB](/infrastructure/aws/adapters/eventlog)

## Data Structure

Events are stored in a `Dict<string, array<JSON.t>>` managed by an STM `TRef`. The dictionary key is the aggregate ID, and the value is an ordered array of event JSON objects.

## Operations

| Operation | Description |
|-----------|-------------|
| `append` | Appends JSON events to the array for a given aggregate ID |
| `replay` | Returns all events for an aggregate ID as an array |
| `replayStream` | Returns events as an Effect `Stream` for API uniformity |
| `appendStream` | Appends events from a stream sequentially |

## Bus Integration

When created via `Make(Bus)`, the adapter registers its `replay` function in the bus so that other components (GraphQL resolvers, MCP resources) can look up event history by aggregate name.

## Key Differences from AWS

| Aspect | InMemory | AWS |
|--------|----------|-----|
| Storage | In-memory `Dict` via STM TRef | DynamoDB table with `id` + `sequenceNr` keys |
| Concurrency | STM transactions (single-threaded) | DynamoDB optimistic concurrency |
| Persistence | None | Durable |
| Streaming | In-memory array wrapped as `Stream` | DynamoDB paginated query |
