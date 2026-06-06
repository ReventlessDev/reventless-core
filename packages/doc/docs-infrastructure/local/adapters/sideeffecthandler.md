---
title: SideEffectHandler
sidebar_position: 12
---

# SideEffectHandler — Local

**Source:** `reventless-local/src/adapter/LocalSideEffectHandler.res`

## How It Works

The Local SideEffectHandler delegates schedule operations (`createSchedule`, `deleteSchedule`) to the provided Scheduler adapter. The `enqueueEvent` operation is a no-op.

In typical test scenarios, `TaskSpec.setup` returns `sideEffects: None`, so this adapter is rarely instantiated.

## Operations

| Operation | Description |
|-----------|-------------|
| `enqueueEvent` | No-op |
| `createSchedule` | Delegates to the Scheduler adapter |
| `deleteSchedule` | Delegates to the Scheduler adapter |

## Key Differences from AWS

| Aspect | Local | AWS |
|--------|----------|-----|
| Event enqueue | No-op | SQS message send |
| Scheduling | Delegates to LocalScheduledPublisher | CloudWatch Events |
| Lambda | Not needed | Dedicated Lambda for side effect processing |
