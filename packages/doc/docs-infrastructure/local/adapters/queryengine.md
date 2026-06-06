---
title: QueryEngine
sidebar_position: 10
---

# QueryEngine — Local

**Source:** `reventless-local/src/adapter/QueryEngine/LocalQueryEngine.res`

**AWS equivalent:** [QueryEngine → DynamoDB](/infrastructure/aws/adapters/queryengine)

## How It Works

Created via `Make(Bus)` functor. Uses the bus's QueryDb registries to look up data:

- **`scan`** — calls `Bus.getQueryDbStream(readModelName)` and applies `Stream.take(limit)` to honour the limit without loading all items. Falls back to `Bus.getQueryDbScan` for backward compatibility.
- **`query`** — calls `Bus.getQueryDb(readModelName)` to get the operations record, then uses `loadStream` with optional `Stream.take(limit)`.

## Operations

| Operation | Description |
|-----------|-------------|
| `scan` | Full scan of a read model's data with optional limit |
| `query` | Key-based lookup with optional limit |

## Key Differences from AWS

| Aspect | Local | AWS |
|--------|----------|-----|
| Scan | In-memory array/stream iteration | DynamoDB Scan with filter expressions |
| Query | Dict key lookup | DynamoDB Query with key conditions |
| Indexes | Not supported | secondary index/LSI support |
| Filtering | None (returns all matches) | DynamoDB filter expressions |
