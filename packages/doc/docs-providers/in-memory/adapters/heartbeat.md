---
title: Heartbeat
sidebar_position: 9
---

# Heartbeat — InMemory

**Source:** `reventless-in-memory/src/adapter/Heartbeat/HeartbeatRunner_InMemory.res`

**AWS equivalent:** [Heartbeat → CloudWatch Events](/providers/aws/adapters/heartbeat)

## How It Works

Uses `setInterval` to fire the heartbeat handler at the configured timeout interval (converted from minutes to milliseconds). The handler is obtained via an Effect `Deferred` — after the first tick, subsequent calls resolve immediately.

Active timer handles are tracked in a module-level dictionary for cleanup.

## Operations

| Operation | Description |
|-----------|-------------|
| `make` | Creates a `setInterval` timer that invokes the handler periodically |

## Test Utilities

| Function | Description |
|----------|-------------|
| `reset()` | Clears all active interval timers — call in `afterAll` or `afterEach` |

## Key Differences from AWS

| Aspect | InMemory | AWS |
|--------|----------|-----|
| Scheduling | `setInterval` | CloudWatch Events rule |
| Timer resolution | Milliseconds | Minutes (CloudWatch minimum) |
| Cleanup | Manual `reset()` call | CloudWatch rule deletion |
