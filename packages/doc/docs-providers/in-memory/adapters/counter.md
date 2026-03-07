---
title: Counter
sidebar_position: 8
---

# Counter — InMemory

**Source:** `reventless-in-memory/src/adapter/Counter/CounterHandler_InMemory.res`

**AWS equivalent:** [Counter → DynamoDB Streams](/providers/aws/adapters/counter)

## Data Structure

Counter values are stored in a module-level `Dict<string, int>`. A second `Dict<string, bool>` tracks which `(counterId, targetRef)` pairs have already been counted, providing deduplication.

## Operations

| Operation | Description |
|-----------|-------------|
| `addToCounterTarget` | Increments the counter for a given `counterId` by `target`, skipping if `targetRef` was already counted |

## Test Utilities

| Function | Description |
|----------|-------------|
| `getCount(counterId)` | Returns the current count for a counter ID |
| `reset()` | Clears all counters and deduplication state — call in `beforeEach` |

## Key Differences from AWS

| Aspect | InMemory | AWS |
|--------|----------|-----|
| Storage | Module-level `Dict` | DynamoDB tables (references + counts) |
| Deduplication | In-memory `(counterId, targetRef)` tracking | DynamoDB conditional writes |
| Trigger | Direct function call | DynamoDB Streams |
| Persistence | None — call `reset()` between tests | Durable |
