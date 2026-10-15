---
title: ScheduledPublisher
sidebar_position: 11
---

# ScheduledPublisher — Local

**Source:** `reventless-local/src/adapter/Scheduler/LocalScheduledPublisher.res`

**AWS equivalent:** [ScheduledPublisher → EventBridge Scheduler](/infrastructure/aws/adapters/scheduledpublisher)

## How It Works

Created via `Make(Bus)` functor. For each schedule it waits for the next firing that
`ScheduleTime.nextFiring` names, publishes the payload as an event on the bus, and waits
again. `ScheduleTime` is the same reading of a time that builds the AWS expression, so a
schedule fires at the same times locally and on AWS:

- `Every(interval)` — one interval after it is set, then every interval.
- `Calendar(...)` — at the wall-clock time in its zone; a day whose time falls in the hour
  daylight saving skips does not fire.
- `Once(...)` — once; an `After` is counted from the moment it is set, and a moment
  already past never fires.

A firing further away than a timer can wait is reached a day at a time.

## Operations

| Operation | Description |
|-----------|-------------|
| `createSchedule` | Validates the time and starts waiting; replaces a schedule of the same name |
| `deleteSchedule` | Stops the schedule of that name |

## Test Utilities

| Function | Description |
|----------|-------------|
| `reset()` | Clears all active timers — call in `afterAll` or `afterEach` |

## Key Differences from AWS

| Aspect | Local | AWS |
|--------|----------|-----|
| Scheduling | `setTimeout` to each next firing | EventBridge Scheduler schedules |
| Time expressions | `ScheduleTime.nextFiring` | `ScheduleTime.toAws`: `rate`, `cron` or `at` |
| Payload delivery | Bus event publish | Scheduler → SQS |
| Survives a restart | No | Yes |
