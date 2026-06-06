---
title: QueryDb
sidebar_position: 5
---

# QueryDb — InMemory

**Source:** `reventless-local/src/adapter/QueryDb/QueryDbStorage_InMemory.res`

**AWS equivalent:** [QueryDb → DynamoDB](/infrastructure/aws/adapters/querydb)

## Data Structure

Items are stored in a `Dict<string, array<JSON.t>>` (a `ref`). The key is the item ID. A secondary `allItems` array is kept in sync for scan operations.

## Operations

| Operation | Description |
|-----------|-------------|
| `load` | Returns items for a given ID |
| `loadStream` | Stream variant of `load` |
| `save` | Stores a single item by ID |
| `saveBatch` | Stores multiple items |
| `count` | Returns the increment value (no actual counter tracking) |
| `delete` | Removes an item by ID |
| `deleteBatch` | Removes multiple items |

## Bus Integration

When created via `Make(Bus)`, the adapter registers three functions on the bus:
- `registerQueryDb` — the full operations record for GraphQL resolvers
- `registerQueryDbScan` — a `() => array<JSON.t>` function for full scans
- `registerQueryDbStream` — a `() => Stream<JSON.t>` function for streaming scans (used by QueryEngine with `~limit`)

## Key Differences from AWS

| Aspect | InMemory | AWS |
|--------|----------|-----|
| Storage | In-memory `Dict` | DynamoDB table |
| Indexes | Ignored (all lookups by primary key) | secondary index support with configurable projections |
| TTL | Ignored | DynamoDB TTL attribute |
| AppSync | None | DataSource integration for GraphQL |
