---
title: Task
---

For a short summary of a Task, see [Reventless Components Overview.](../component-overview.md)

:::info Framework Implementation
This component follows the Reventless [Component Structure Pattern](/framework/internals/component-structure-pattern), using separate files for interface definitions (`Task.res`), builder logic (`Task_Builder.res`), and adapter interface (`Task_Adapter.res`).
:::

## Overview

The Task component provides file-based task processing capabilities, enabling event-driven workflows triggered by file uploads, downloads, and external system integrations. Unlike other Reventless components that follow strict Command/Event patterns, Tasks offer flexible implementation approaches for integrating with third-party systems.

```d2
ExternalSystem: External System { class: external-system }
S3Bucket: S3 Bucket { class: aws-service }
Lambda: Lambda Function { class: aws-service }
CommandTopic: Command Topic { class: command-topic }
Aggregate: Aggregate { class: aggregate }
SideEffectHandler: Side Effect Handler { class: side-effect }

ExternalSystem -> S3Bucket: uploads file
S3Bucket -> Lambda: triggers
Lambda -> CommandTopic: publishes commands { class: command-flow }
CommandTopic -> Aggregate: processes { class: command-flow }
Lambda -> SideEffectHandler: can include
```

## Purpose and Responsibilities

- **Responsibility:** Process file-based tasks and integrate with external systems
- **In:** File uploads/changes, external API calls, third-party system events
- **Out:** Commands to aggregates, scheduled tasks, side effect processing

## Task Specification

Tasks are defined using a module specification that includes the task name and setup configuration:

### Basic Task Structure

A Task is a single file `Task/<Name>.res` annotated with `@@reventless.task`. The
PPX injects `let name` (from the filename stem), `let moduleUrl`, and
`open Reventless` — you only write `let setup`, returning a `Task.config`:

```rescript title="Task/ProfilePictures.res" showLineNumbers
@@reventless.task

let setup = (_queryEngine, _queryBucketName, _opts): Task.config => {
  Task.buckets: [
    {
      bucketName: "profile-pictures",
      bucketMode: Task.ReadWrite,
      callback: profilePictureCallback,
    },
  ],
}
```

The plugin generator wires the Task into the generated `Plugin.res` as
`Platform.Task.Make(ProfilePictures)` — a single argument. You never write the
composition root by hand.

### Task Configuration

The setup function returns a configuration object that defines the task's behavior:

```rescript
type config = {
  buckets?: array<bucketSpec>,           // S3 buckets for file processing
  sideEffects?: SideEffectHandler.sideEffects,  // Event-driven side effects
}

type bucketSpec = {
  bucketName?: string,                   // Custom bucket name (optional)
  bucketMode: bucketMode,                // Read, Write, or ReadWrite access
  callback?: bucketCallback,             // Function to handle file events
}

type bucketMode = Read | Write | ReadWrite

type bucketCallback = (~eventName: string, ~key: string) => promise<array<taskAction>>
```

### Task Actions

Task callbacks can return various actions to be executed:

```rescript
type taskAction =
  | PublishCommands(string, array<Message.commandJson>)  // Send commands to aggregates
  | CreateSchedule(Reventless.Schedule.schedule)     // Create scheduled tasks
  | DeleteSchedule(string)                               // Remove scheduled tasks
```

## Runtime Operations

Tasks have access to several runtime operations through their setup function parameters:

### Query Engine Operations

The `queryEngine` parameter provides access to read model data during runtime:

```rescript
// Query specific entries by ID
let customerData = await queryEngine.query(
  ~tableName="Customer",
  ~id="customer-123",
  ~filterExpression=Some("attribute_exists(email)"),
)

// Scan all entries with filter criteria
let activeCustomers = await queryEngine.scan(
  ~tableName="Customer",
  ~filterExpression=Some("active = :active"),
  ~expressionAttributeValues=Dict.fromArray([
    (":active", true->DynamoDb.AttributeValue.bool)
  ]),
)
```

**Key features:**
- **Query by ID** - Efficient retrieval for specific entities
- **Scan with filters** - Broader searches across read models
- **DynamoDB integration** - Direct access to read model storage

### Bucket Name Resolution

The `queryBucketName` function provides standardized bucket naming:

```rescript
// Get bucket name for task
let bucketName = queryBucketName(~taskName="ProfilePictureTask")
// Returns: "ProfilePictureTaskBucket"

// Get bucket name with custom suffix
let customBucket = queryBucketName(
  ~taskName="ProfilePictureTask",
  ~bucketName="Images"
)
// Returns: "ProfilePictureTaskImages"
```

## Usage Patterns

### File Processing Task

```rescript title="Task/ProfilePictures.res" showLineNumbers
@@reventless.task

let profilePictureCallback = (~eventName, ~key) => {
  let customerId = key->String.split(".")->Array.getUnsafe(0)
  let isCreation = eventName->String.includes("ObjectCreated")
  let isDeletion = eventName->String.includes("ObjectRemoved")

  let actions = []

  if isCreation {
    actions->Array.push(
      Task.PublishCommands(
        "Customer",
        [
          {
            Message.id: customerId,
            meta: Message.generateMeta(~service="ProfilePictures", ~user="system"),
            commandJson: Customer.ChangeProfilePicture(Some(key))->Customer.command_encode,
          },
        ],
      ),
    )
  } else if isDeletion {
    actions->Array.push(
      Task.PublishCommands(
        "Customer",
        [
          {
            Message.id: customerId,
            meta: Message.generateMeta(~service="ProfilePictures", ~user="system"),
            commandJson: Customer.ChangeProfilePicture(None)->Customer.command_encode,
          },
        ],
      ),
    )
  }

  Promise.resolve(actions)
}

let setup = (_queryEngine, _queryBucketName, _opts): Task.config => {
  Task.buckets: [
    {
      bucketName: "profile-pictures",
      bucketMode: Task.ReadWrite,
      callback: profilePictureCallback,
    },
  ],
}
```

### Task with Side Effects

```rescript title="Task/DocumentProcessing.res" showLineNumbers
@@reventless.task

let documentCallback = (~eventName, ~key) =>
  if eventName->String.includes("ObjectCreated") {
    // Schedule document processing
    [
      Task.CreateSchedule({
        name: `process-document-${key}`,
        rate: Minutes(5), // Process in 5 minutes
        payload: `{"documentKey": "${key}", "action": "process"}`,
      }),
    ]->Promise.resolve
  } else {
    []->Promise.resolve
  }

let setup = (_queryEngine, _queryBucketName, _opts): Task.config => {
  Task.buckets: [
    {
      bucketName: "documents",
      bucketMode: Task.Read,
      callback: documentCallback,
    },
  ],
  sideEffects: [
    // Side effect to handle document processing events
    module(DocumentProcessingSideEffect),
  ],
}
```

## Runtime Behavior

Tasks operate through an event-driven flow triggered by file operations:

### File Upload Flow

```d2
shape: sequence_diagram

Client: Client Application { class: client }
S3: S3 Bucket { class: aws-service }
Lambda: Task Lambda { class: aws-service }
CT: Command Topic { class: command-topic }
Agg: Aggregate { class: aggregate }

Client -> S3: Upload file
S3 -> Lambda: Trigger ObjectCreated event
Lambda -> Lambda: Execute callback function
Lambda -> CT: Publish commands
CT -> Agg: Process commands
Agg --> Lambda: Command processed
```

### Integration with Scheduler

```d2
shape: sequence_diagram

S3: S3 Bucket { class: aws-service }
Lambda: Task Lambda { class: aws-service }
Scheduler: Scheduler { class: scheduler }
Target: Target Service { class: external-system }

S3 -> Lambda: File event
Lambda -> Scheduler: CreateSchedule action
Scheduler -> Scheduler: Create CloudWatch rule
Scheduler -> Target: "Trigger scheduled action (executes later)"
```

## Integration Points

Tasks integrate with multiple Reventless components to enable comprehensive workflows:

### Integration with Aggregates

```d2
Task: Task { class: task }
CommandTopic: Command Topic { class: command-topic }
Aggregate: Aggregate { class: aggregate }
EventTopic: Event Topic { class: event-topic }

Task -> CommandTopic: PublishCommands { class: command-flow }
CommandTopic -> Aggregate: commands { class: command-flow }
Aggregate -> EventTopic: events { class: event-flow }
```

### Integration with Scheduler

```rescript
// Task can create dynamic schedules
let scheduleCleanup = Task.CreateSchedule({
  name: "cleanup-temp-files",
  rate: Daily(2, 0), // 2:00 AM daily
  payload: `{"action": "cleanup", "target": "temp-files"}`,
})

// Task can also delete schedules
let removeSchedule = Task.DeleteSchedule("cleanup-temp-files")
```

### Integration with Side Effect Handler

Tasks can include side effect handlers to react to events from other components:

```rescript title="Task/DocumentProcessing.res" showLineNumbers
@@reventless.task

let setup = (_queryEngine, _queryBucketName, _opts): Task.config => {
  Task.buckets: [/* bucket configuration */],
  sideEffects: [
    module(DocumentProcessingSideEffect),
    module(NotificationSideEffect),
  ],
}
```

## Common Patterns

### File Upload Processing

```rescript
// Handle profile picture uploads
let profilePictureCallback = (~eventName, ~key) => {
  let userId = extractUserIdFromKey(key)

  if eventName->String.includes("ObjectCreated") {
    [
      Task.PublishCommands(
        "User",
        [
          {
            Message.id: userId,
            meta: Message.generateMeta(~service="ProfilePictures"),
            commandJson: User.UpdateProfilePicture(key)->User.command_encode,
          },
        ],
      ),
    ]->Promise.resolve
  } else {
    []->Promise.resolve
  }
}
```

### Document Processing Pipeline

```rescript
// Multi-stage document processing
let documentCallback = (~eventName, ~key) =>
  if eventName->String.includes("ObjectCreated") {
    [
      // Immediate processing
      Task.PublishCommands(
        "Document",
        [
          {
            Message.id: extractDocumentId(key),
            meta: Message.generateMeta(~service="DocumentProcessing"),
            commandJson: Document.StartProcessing(key)->Document.command_encode,
          },
        ],
      ),
      // Scheduled follow-up
      Task.CreateSchedule({
        name: `document-followup-${key}`,
        rate: Hours(24), // Check status after 24 hours
        payload: `{"documentKey": "${key}", "action": "checkStatus"}`,
      }),
    ]->Promise.resolve
  } else {
    []->Promise.resolve
  }
```

### Batch Processing

```rescript
// Process files in batches
let batchCallback = (~eventName, ~key) =>
  if eventName->String.includes("ObjectCreated") {
    [
      // Add to batch queue
      Task.PublishCommands(
        "BatchProcessor",
        [
          {
            Message.id: "batch-queue",
            meta: Message.generateMeta(~service="BatchProcessing"),
            commandJson: BatchProcessor.AddToBatch(key)->BatchProcessor.command_encode,
          },
        ],
      ),
      // Schedule batch processing if queue is full
      Task.CreateSchedule({
        name: "process-batch",
        rate: Minutes(5), // Process batch every 5 minutes
        payload: `{"action": "processBatch"}`,
      }),
    ]->Promise.resolve
  } else {
    []->Promise.resolve
  }
```

## Pulumi

The Task component is deployed as infrastructure that creates S3 buckets, Lambda functions, and event subscriptions. The actual file processing happens automatically when files are uploaded or modified.

You don't wire the Task by hand. The plugin generator scans the `Task/` folder
and emits the wiring into the **generated** `Plugin.res`:

```rescript title="src/Plugin.res (generated — do not edit)"
module Make = (Platform: ReventlessInfra.Platform.T) => {
  // Tasks
  module ProfilePicturesTask = Platform.Task.Make(ProfilePictures)

  let make = (~uiBundleUrl=?) =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~tasks=[module(ProfilePicturesTask)],
      // ... other components
    )
}
```

## AWS Implementation

For detailed AWS-specific implementation including S3 bucket configuration, Lambda event subscriptions, IAM policies, and CORS settings, see [Task → Lambda + SQS](/infrastructure/aws/adapters/task).
