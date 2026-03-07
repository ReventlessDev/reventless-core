---
title: "ScheduledPublisher → EventBridge Scheduler"
date: 2026-01-15
draft: false
---

## ScheduledPublisher → CloudWatch Events

The ScheduledPublisher adapter provides time-based event publishing capabilities using Amazon CloudWatch Events (now Amazon EventBridge), enabling scheduled workflows, periodic tasks, and cron-like event generation.

## IAM Role Configuration

The ScheduledPublisher adapter creates an IAM role with permissions for CloudWatch Events to manage scheduled rules:

```rescript
let role = PulumiAws.IAM.Role.makeWithDefaultPolicy(
  ~name="CloudWatchEventsRole",
  ~servicePrincipal=AWS.CloudwatchEventRule.principal->Pulumi.Output.make,
  ~opts,
)

let _policy = PulumiAws.IAM.Policy.make(
  ~name=name++"CloudWatchEventsPolicy",
  ~args={
    PulumiAws.IAM.Policy.policy: role.arn
    ->Pulumi.Output.apply(roleArn => {
      open PulumiAws.PolicyDocument
      PulumiAws.PolicyDocument.make(
        ~id = name ++ "CloudWatchEventsPolicy",
        ~statements=[
          {
            sid: "AllowCloudWatchEvents",
            effect: Allow,
            actions: Action("events:*"),
            resources: AllResources,
          },
          {
            sid: "AllowPassRole",
            effect: Allow,
            actions: Action("iam:PassRole"),
            resources: Resource(`${roleArn}`),
          },
        ],
      )->toJsonString
    })
    ->Pulumi.Output.asInput,
  },
  ~opts,
)
```

**IAM configuration details:**

- **Service Principal** - CloudWatch Events service (`events.amazonaws.com`) is granted AssumeRole permissions
- **`events:*` permissions** - Full access to CloudWatch Events operations
  - Create, update, and delete event rules
  - Add and remove targets from rules
  - Enable and disable rules
- **`iam:PassRole` permission** - Allows CloudWatch Events to pass the role to targets (e.g., Lambda, ECS)
  - Required when event rules invoke services on behalf of the role
  - Scoped to the specific role ARN for security

**Key features:**

- **Deploy-time role creation** - IAM role and policies are provisioned during deployment
- **Least privilege principle** - Role is scoped to CloudWatch Events service only
- **Target invocation** - PassRole permission enables CloudWatch Events to invoke configured targets

## Runtime Operations

The ScheduledPublisher adapter provides two runtime operations for managing scheduled events:

## Create Schedule Operation

The `createSchedule` operation dynamically creates CloudWatch Event Rules at runtime:

```rescript
createSchedule: ScheduledPublisher_CloudWatchEvents_Runtime.createSchedule(role)
```

**Key features:**

- **Dynamic rule creation** - Create event rules programmatically from Lambda or application code
- **Flexible scheduling** - Supports cron expressions and rate expressions
  - Cron: `cron(0 12 * * ? *)` - Daily at 12:00 PM UTC
  - Rate: `rate(5 minutes)` - Every 5 minutes
- **Target configuration** - Configure which resources (Lambda, SQS, etc.) receive scheduled events
- **Role binding** - Uses the CloudWatch Events role created at deploy-time

**Use cases:**

- Create temporary schedules based on business logic
- Schedule tasks with dynamic intervals (e.g., user-configured reminder times)
- Enable/disable scheduled workflows programmatically

## Delete Schedule Operation

The `deleteSchedule` operation removes CloudWatch Event Rules at runtime:

```rescript
deleteSchedule: ScheduledPublisher_CloudWatchEvents_Runtime.deleteSchedule
```

**Key features:**

- **Dynamic rule deletion** - Remove event rules when no longer needed
- **Cleanup automation** - Automatically remove temporary schedules after completion
- **Resource management** - Prevent accumulation of unused event rules

**Use cases:**

- Remove schedules when users unsubscribe from notifications
- Clean up temporary workflows after task completion
- Disable periodic checks when conditions are met

## Deploy-time to Runtime Flow

The ScheduledPublisher adapter follows a simplified deploy-time/runtime pattern focused on IAM setup:

```rescript
let make: Reventless.Scheduler_Adapter.scheduledPublisherMaker = (~name, ~opts) => {
  // Deploy-time: Create IAM role and policy for CloudWatch Events
  let role = PulumiAws.IAM.Role.makeWithDefaultPolicy(
    ~name="CloudWatchEventsRole",
    ~servicePrincipal=AWS.CloudwatchEventRule.principal->Pulumi.Output.make,
    ~opts,
  )

  let _policy = PulumiAws.IAM.Policy.make(/* ... */)

  {
    resource: {
      Reventless.Adapter.service: "CloudWatchEvents"->Pulumi.Output.make,
      name: ""->Pulumi.Output.make,
      id: ""->Pulumi.Output.make,
      urn: ""->Pulumi.Output.make,
      info: ""->Pulumi.Output.make,
    },
    operations: {
      Reventless.Scheduler.createSchedule: ScheduledPublisher_CloudWatchEvents_Runtime.createSchedule(role),
      deleteSchedule: ScheduledPublisher_CloudWatchEvents_Runtime.deleteSchedule,
    }->Pulumi.Output.make,
  }
}
```

**Flow steps:**

1. **Create IAM role** - Pulumi provisions role with CloudWatch Events service principal
2. **Attach policies** - Policy document grants `events:*` and `iam:PassRole` permissions
3. **Bind runtime functions** - `createSchedule` receives role for target configuration
4. **Lambda execution** - Runtime functions execute in Lambda, using CloudWatch Events SDK

**Differences from other adapters:**

- **No resource metadata extraction** - Unlike DynamoDB/SQS adapters, no `toRuntime*Output` conversion
- **Role-based binding** - Runtime functions receive the IAM role itself, not metadata
- **Dynamic resource creation** - CloudWatch Event Rules are created at runtime, not deploy-time
- **Operations wrapped directly** - No `Pulumi.Output.apply` needed for operations binding

## When to Use ScheduledPublisher

**Use ScheduledPublisher for:**

- **Periodic event generation** - Trigger workflows at fixed intervals
  - Daily report generation
  - Hourly data synchronization
  - Weekly cleanup tasks
- **Cron-like scheduling** - Complex time-based patterns
  - Business day processing (Monday-Friday only)
  - Monthly billing runs (first day of each month)
  - Quarterly reports
- **Time-based commands** - Publish commands on a schedule
  - Send reminder commands
  - Trigger health checks
  - Initiate batch processing
- **Dynamic scheduling** - Create/delete schedules based on business logic
  - User-configured notification times
  - Temporary event monitoring windows
  - Conditional polling intervals

**Common patterns:**

- **Scheduled Commands** - CloudWatch Event → Lambda → CommandTopic → Aggregate
  - Event rule triggers Lambda
  - Lambda publishes command to CommandTopic
  - Aggregate processes command
- **Periodic Queries** - CloudWatch Event → Lambda → QueryDb → EventTopic
  - Event rule triggers Lambda
  - Lambda queries read models
  - Lambda publishes events based on query results
- **Batch Processing** - CloudWatch Event → Lambda → S3 Task Bucket
  - Event rule triggers Lambda
  - Lambda generates batch task files
  - S3 upload triggers processing pipeline

