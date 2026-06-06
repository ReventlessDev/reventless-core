---
title: ScheduledPublisher
sidebar_position: 11
---

# ScheduledPublisher — Local

**Source:** `reventless-local/src/adapter/Scheduler/LocalScheduledPublisher.res`

**AWS equivalent:** [ScheduledPublisher → CloudWatch Events](/infrastructure/aws/adapters/scheduledpublisher)

## How It Works

Created via `Make(Bus)` functor. Schedules are implemented using `setInterval` (for recurring rates) or `setTimeout` (for single-shot `Single(...)` schedules). When triggered, the timer publishes the schedule's payload as an event to the bus.

Schedule rates are converted to milliseconds:
- `Minutes(n)` → `n * 60 * 1000`
- `Hours(n)` → `n * 60 * 60 * 1000`
- `Days(n)` → `n * 24 * 60 * 60 * 1000`
- `Single(...)` → fires immediately (`setTimeout(fn, 0)`)

## Operations

| Operation | Description |
|-----------|-------------|
| `createSchedule` | Sets up a timer that publishes events to the bus topic |
| `deleteSchedule` | Clears the timer for a given schedule name |

## Test Utilities

| Function | Description |
|----------|-------------|
| `reset()` | Clears all active timers — call in `afterAll` or `afterEach` |

## Key Differences from AWS

| Aspect | Local | AWS |
|--------|----------|-----|
| Scheduling | `setInterval` / `setTimeout` | CloudWatch Events rules |
| Rate expressions | Converted to milliseconds | CloudWatch rate/cron expressions |
| Payload delivery | Bus event publish | CloudWatch → Lambda → SQS |
