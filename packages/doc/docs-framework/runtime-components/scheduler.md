---
title: Scheduler
---

For a short summary of a Scheduler, see [Reventless Components Overview.](/app/component-overview)

:::info Framework Implementation
This component follows the Reventless [Component Structure Pattern](/framework/internals/component-structure-pattern), using separate files for interface definitions (`Scheduler.res`), builder logic (`Scheduler_Builder.res`), and adapter interface (`Scheduler_Adapter.res`).
:::

## Overview

The Scheduler component provides time-based command publishing capabilities, enabling scheduled workflows, periodic tasks, and cron-like event generation. It allows applications to create and manage schedules dynamically at runtime.

```d2
Application: Application Code { class: client }
Scheduler: Scheduler { class: scheduler }
CloudWatch: EventBridge Scheduler { class: aws-service }
CommandTopic: Command Topic { class: command-topic }

Application -> Scheduler: createSchedule { class: command-flow }
Application -> Scheduler: deleteSchedule { class: command-flow }
Scheduler -> CloudWatch: manages
CloudWatch -> CommandTopic: triggers
```

## Purpose and Responsibilities

- **Responsibility:** Manage time-based event scheduling and command publishing
- **In:** Schedule definitions with timing patterns and payloads
- **Out:** Scheduled events/commands published to configured targets

## Schedule Specification

The Scheduler uses a flexible schedule specification that supports various timing patterns:

### Schedule Types

`Schedule.time` has one constructor per shape of a time:

```rescript
type interval = Minutes(int) | Hours(int) | Days(int) | Weeks(int)
type weekday = Mon | Tue | Wed | Thu | Fri | Sat | Sun
type calendar =
  | Daily({hour: hour, minute: minute})
  | Weekly({days: array<weekday>, hour: hour, minute: minute})
  | Monthly({day: day, hour: hour, minute: minute, every?: int}) // every: 3 is quarterly
  | Yearly({month: month, day: day, hour: hour, minute: minute})
type period = Minutes(int) | Hours(int) | Days(int) | Weeks(int) | Months(int) | Years(int)
type localTime = {year: year, month: month, day: day, hour: hour, minute: minute}
type moment = At(localTime) | After(period)
type zone = string // an IANA name such as "Europe/Berlin"; absent means UTC

type time =
  | Every(interval)                              // a fixed length, from the previous firing
  | Calendar({calendar: calendar, zone?: zone})  // a wall-clock time that recurs
  | Once({moment: moment, zone?: zone})          // a single moment

type schedule = {
  name: string,      // Unique identifier for the schedule
  time: time,        // When it fires
  payload: string,   // Data to publish when the schedule fires
}
```

- **Daylight saving.** A calendar time in the hour daylight saving skips does not fire
  that day; one in the repeated hour fires once. Both platforms follow this rule.
- **Months and years are not intervals.** *Every month* is a calendar time (`Monthly`).
  A `Monthly` day that a month lacks (the 31st) is skipped in that month.
- **`After` is counted from the moment the schedule is created**, by the calendar of its
  zone: a month from 31 January is the last day of February. A once-only time already
  past never fires.
- **An invalid time is refused** when the schedule is created: an unknown zone, an hour
  of 24 or a weekly time without days.

### Example Schedule Definitions

```rescript
// Daily report generation at 09:00 in Berlin
let dailyReport = {
  Reventless.Schedule.name: "daily-report",
  time: Calendar({calendar: Daily({hour: 9, minute: 0}), zone: "Europe/Berlin"}),
  payload: `{"type": "GenerateReport", "reportType": "daily"}`,
}

// Cleanup task every 6 hours
let cleanupTask = {
  name: "cleanup-task", 
  time: Every(Hours(6)),
  payload: `{"type": "CleanupTempFiles"}`,
}

// One-time reminder
let reminder = {
  name: "meeting-reminder",
  time: Once({moment: At({year: 2026, month: 12, day: 25, hour: 14, minute: 30})}),
  payload: `{"type": "SendReminder", "meetingId": "abc123"}`,
}
```

## Usage Patterns

### Basic Scheduler Setup

```rescript
// In your plugin definition
module MyPlugin = {
  let scheduler = Reventless.Scheduler.make()
  
  // Access scheduler operations at runtime
  let scheduleOperations = scheduler.operations
}
```

### Runtime Schedule Management

```rescript
// Create a schedule dynamically
let createDailyBackup = async () => {
  let schedule = {
    Reventless.Schedule.name: "daily-backup",
    time: Calendar({calendar: Daily({hour: 2, minute: 0})}), // 02:00 UTC daily
    payload: `{"type": "StartBackup", "target": "database"}`,
  }
  
  await scheduler.operations.createSchedule([], schedule)
}

// Remove a schedule when no longer needed
let removeSchedule = async (scheduleName) => {
  await scheduler.operations.deleteSchedule([], scheduleName)
}
```

## Runtime Behavior

The Scheduler component operates through two main runtime operations:

### Schedule Creation Flow

```d2
shape: sequence_diagram

App: Application { class: external-system }
Sched: Scheduler { class: scheduler }
CW: EventBridge Scheduler { class: aws-service }
Target: Target Service { class: external-system }

App -> Sched: "createSchedule(schedule)"
Sched -> CW: "CreateSchedule (rate, cron or at, with its zone and target)"
CW --> Sched: Schedule Created
Sched --> App: Schedule Active
CW -> Target: "Trigger on Schedule (schedule runs automatically)"
Target -> Target: Process Payload
```

### Schedule Deletion Flow

```d2
shape: sequence_diagram

App: Application { class: external-system }
Sched: Scheduler { class: scheduler }
CW: EventBridge Scheduler { class: aws-service }

App -> Sched: "deleteSchedule(name)"
Sched -> CW: DeleteSchedule
CW --> Sched: Schedule Deleted
Sched --> App: Schedule Removed
```

## Integration Points

The Scheduler integrates with other Reventless components to enable time-based workflows:

### Common Integration Patterns

```d2
Scheduler: Scheduler { class: scheduler }
CommandTopic: Command Topic { class: command-topic }
Aggregate: Aggregate { class: aggregate }
EventTopic: Event Topic { class: event-topic }
ReadModel: Read Model { class: read-model }

Scheduler -> CommandTopic: scheduled commands { class: command-flow }
CommandTopic -> Aggregate: commands { class: command-flow }
Aggregate -> EventTopic: events { class: event-flow }
EventTopic -> ReadModel: events { class: projection-flow }
```

### Integration with Command Topics

```rescript
// Scheduler publishes to CommandTopic for aggregate processing
let scheduleAggregateCommand = {
  name: "process-orders",
  time: Every(Hours(1)),
  payload: `{"aggregateId": "order-processor", "command": "ProcessPendingOrders"}`,
}
```

### Integration with Event Topics

```rescript
// Scheduler can trigger event publication for system monitoring
let healthCheckSchedule = {
  name: "health-check",
  time: Every(Minutes(5)),
  payload: `{"type": "HealthCheckEvent", "timestamp": "${Date.now()}"}`,
}
```

## Common Patterns

### Periodic Data Processing

```rescript
// Process batch data every hour
let batchProcessor = {
  name: "batch-processor",
  time: Every(Hours(1)),
  payload: `{"type": "ProcessBatch", "batchSize": 1000}`,
}
```

### Business Hours Scheduling

```rescript
// Send daily reports only on weekdays
let businessReport = {
  name: "business-report",
  time: Calendar({calendar: Weekly({days: [Mon, Tue, Wed, Thu, Fri], hour: 17, minute: 0})}),
  payload: `{"type": "GenerateBusinessReport"}`,
}
```

### Cleanup and Maintenance

```rescript
// Daily cleanup at midnight
let dailyCleanup = {
  name: "daily-cleanup",
  time: Calendar({calendar: Daily({hour: 0, minute: 0})}),
  payload: `{"type": "CleanupExpiredData"}`,
}
```

### Dynamic User Schedules

```rescript
// Create user-specific reminder schedules
let createUserReminder = async (userId, reminderTime: Reventless.Schedule.localTime, zone) => {
  let schedule = {
    name: `user-reminder-${userId}`,
    time: Once({moment: At(reminderTime), zone}),
    payload: `{"type": "UserReminder", "userId": "${userId}"}`,
  }
  
  await scheduler.operations.createSchedule([], schedule)
}
```

## Pulumi

The Scheduler component is deployed as infrastructure that creates the IAM role EventBridge Scheduler delivers with, and the schedule group the platform's schedules go into. The schedules themselves are created at run time through the component's operations.

```rescript
// Deployment creates the scheduler role and its schedule group
let scheduler = Reventless.Scheduler.make(~opts=pulumiOpts)

// Runtime operations use the deployed role to manage schedules
let operations = scheduler.outputs.resource
```

## AWS Implementation

For detailed AWS-specific implementation including EventBridge integration, IAM role configuration, and runtime operations, see [ScheduledPublisher → EventBridge Scheduler](/infrastructure/aws/adapters/scheduledpublisher).