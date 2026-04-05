---
title: SideEffectHandler
sidebar_position: 12
---

# SideEffectHandler — InMemory

**Source:** `reventless-in-memory/src/adapter/SideEffectHandler_InMemory.res`

## How It Works

The InMemory SideEffectHandler delegates schedule operations (`createSchedule`, `deleteSchedule`) to the provided Scheduler adapter. The `enqueueEvent` operation is a no-op.

In typical test scenarios, `TaskSpec.setup` returns `sideEffects: None`, so this adapter is rarely instantiated.

## Operations

| Operation | Description |
|-----------|-------------|
| `enqueueEvent` | No-op |
| `createSchedule` | Delegates to the Scheduler adapter |
| `deleteSchedule` | Delegates to the Scheduler adapter |

## Key Differences from AWS

| Aspect | InMemory | AWS |
|--------|----------|-----|
| Event enqueue | No-op | SQS message send |
| Scheduling | Delegates to ScheduledPublisher_InMemory | CloudWatch Events |
| Lambda | Not needed | Dedicated Lambda for side effect processing |
