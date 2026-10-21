---
title: "ScheduledPublisher → EventBridge Scheduler"
---

## ScheduledPublisher → EventBridge Scheduler

The ScheduledPublisher adapter creates and deletes schedules at run time in
[Amazon EventBridge Scheduler](https://docs.aws.amazon.com/scheduler/latest/UserGuide/what-is-scheduler.html).
When a schedule fires, Scheduler sends its payload to a queue, usually a command topic.

**Source:** `reventless-aws/src/adapter/ScheduledPublisher/ScheduledPublisher_EventBridgeScheduler.res`
(deploy time) and `ScheduledPublisher_EventBridgeScheduler_Runtime.res` (run time).

## What is deployed

| Resource | Purpose |
|---|---|
| IAM role `SchedulerRole-<suffix>` | assumed by Scheduler (`scheduler.amazonaws.com`) to deliver a payload; may `sqs:SendMessage` |
| Schedule group, named after the role | holds every schedule the platform creates |

The group carries the role's name, so the role ARN that every runtime already receives
also names the group. No schedule is made at deploy time.

The Lambdas that create schedules (the extension points, the plugin connect timeout, Tasks
with side effects) may `scheduler:CreateSchedule`, `UpdateSchedule` and `DeleteSchedule`
on the schedules of that group, and `iam:PassRole` the role to Scheduler. A command topic's
queue policy needs no entry for Scheduler: it sends as the role.

## How a time becomes a schedule

`createSchedule` turns the schedule's `Schedule.time` into Scheduler's expression with
`ScheduleTime.toAws`, the same reading of a time the local timers use:

| `Schedule.time` | Expression | Also set |
|---|---|---|
| `Every(Minutes(5))` | `rate(5 minutes)` | `StartDate` one interval after creation; `Weeks(n)` becomes `rate(7n days)` |
| `Calendar({calendar: Daily({hour: 6, minute: 0})})` | `cron(0 6 * * ? *)` | `ScheduleExpressionTimezone`, `UTC` when the time has no zone |
| `Calendar({calendar: Weekly({days: [Mon, Fri], …})})` | `cron(30 7 ? * MON,FRI *)` | the zone |
| `Calendar({calendar: Monthly({day: 1, every: 3, …})})` | `cron(0 6 1 1/3 ? *)` | the zone |
| `Once({moment: After(Minutes(10))})` | `at(2026-10-15T14:12:00)`, counted from creation | the zone; `ActionAfterCompletion: DELETE` |

- **`StartDate` on an interval.** Without it, Scheduler fires a `rate` schedule as soon as
  it is created.
- **Daylight saving.** Scheduler skips a `cron` time in the hour that daylight saving
  skips, and runs one in the repeated hour once.
- **The time is validated before the call**: an unknown zone, an hour of 24 or a weekly
  time without days is refused with `ScheduleTime.InvalidTime`.

A FIFO queue target (`*.fifo`) gets the schedule's name as its message group; the command
topics deduplicate by content.

## Operations

| Operation | Behavior |
|---|---|
| `createSchedule` | `CreateSchedule` in the group; when one of that name exists, `UpdateSchedule` replaces it |
| `deleteSchedule` | `DeleteSchedule`; a schedule already gone, such as a once-only one that fired, is no error |

Both target the first channel resource they are given, by its ARN.

## Limits

EventBridge Scheduler holds 10,000,000 schedules per region by default, and 500 schedule
groups. A schedule fires within a minute of its time.
