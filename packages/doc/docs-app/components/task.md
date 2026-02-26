---
title: Task
---

For a short summary of a Task, see [Reventless Components Overview.](../component-overview.md#task)

:::info Framework Implementation
This component follows the Reventless [Component Structure Pattern](/framework/inner-workings/component-structure-pattern), using separate files for interface definitions ([`Task.res`](../../reventless/src/components/Task/Task.res)), builder logic ([`Task_Builder.res`](../../reventless/src/components/Task/Task_Builder.res)), and adapter interface ([`Task_Adapter.res`](../../reventless/src/components/Task/Task_Adapter.res)).
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

```rescript
module ProfilePictureTask = {
  let name = "ProfilePictureTask"
  
  let setup = (queryEngine, queryBucketName, opts) => {
    // Task configuration
    {
      buckets: Some([
        {
          bucketName: Some("profile-pictures"),
          bucketMode: ReadWrite,
          callback: Some(profilePictureCallback),
        }
      ]),
      sideEffects: None,
    }
  }
}

// Create the task component
module Task = Reventless.Task.Make(ProfilePictureTask, /* other modules */)
```

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

```rescript
module ProfilePictureTask = {
  let name = "ProfilePictureTask"
  
  let profilePictureCallback = (~eventName, ~key) => {
    let customerId = key->Js.String2.split(".")->Array.getUnsafe(0)
    let isCreation = eventName->Js.String2.includes("ObjectCreated")
    let isDeletion = eventName->Js.String2.includes("ObjectRemoved")
    
    let actions = []
    
    if isCreation {
      actions->Array.push(
        PublishCommands("Customer", [
          {
            Message.id: customerId,
            meta: Message.generateMeta(~service="ProfilePictureTask", ~user="system"),
            commandJson: Customer.ChangeProfilePicture(Some(key))->Customer.command_encode,
          }
        ])
      )
    } else if isDeletion {
      actions->Array.push(
        PublishCommands("Customer", [
          {
            Message.id: customerId,
            meta: Message.generateMeta(~service="ProfilePictureTask", ~user="system"),
            commandJson: Customer.ChangeProfilePicture(None)->Customer.command_encode,
          }
        ])
      )
    }
    
    Promise.resolve(actions)
  }
  
  let setup = (queryEngine, queryBucketName, opts) => {
    {
      buckets: Some([
        {
          bucketName: Some("profile-pictures"),
          bucketMode: ReadWrite,
          callback: Some(profilePictureCallback),
        }
      ]),
      sideEffects: None,
    }
  }
}
```

### Task with Side Effects

```rescript
module DocumentProcessingTask = {
  let name = "DocumentProcessingTask"
  
  let documentCallback = (~eventName, ~key) => {
    if eventName->Js.String2.includes("ObjectCreated") {
      // Schedule document processing
      [
        CreateSchedule({
          name: `process-document-${key}`,
          rate: Minutes(5), // Process in 5 minutes
          payload: `{"documentKey": "${key}", "action": "process"}`,
        })
      ]->Promise.resolve
    } else {
      []->Promise.resolve
    }
  }
  
  let setup = (queryEngine, queryBucketName, opts) => {
    {
      buckets: Some([
        {
          bucketName: Some("documents"),
          bucketMode: Read,
          callback: Some(documentCallback),
        }
      ]),
      sideEffects: Some([
        // Side effect to handle document processing events
        (module DocumentProcessingSideEffect: SideEffect.T)
      ]),
    }
  }
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
let scheduleCleanup = CreateSchedule({
  name: "cleanup-temp-files",
  rate: Daily(2, 0), // 2:00 AM daily
  payload: `{"action": "cleanup", "target": "temp-files"}`,
})

// Task can also delete schedules
let removeSchedule = DeleteSchedule("cleanup-temp-files")
```

### Integration with Side Effect Handler

Tasks can include side effect handlers to react to events from other components:

```rescript
module TaskWithSideEffects = {
  let name = "DocumentTask"
  
  let setup = (queryEngine, queryBucketName, opts) => {
    {
      buckets: Some([/* bucket configuration */]),
      sideEffects: Some([
        (module DocumentProcessingSideEffect: SideEffect.T),
        (module NotificationSideEffect: SideEffect.T),
      ]),
    }
  }
}
```

## Common Patterns

### File Upload Processing

```rescript
// Handle profile picture uploads
let profilePictureCallback = (~eventName, ~key) => {
  let userId = extractUserIdFromKey(key)
  
  if eventName->Js.String2.includes("ObjectCreated") {
    [
      PublishCommands("User", [
        {
          Message.id: userId,
          meta: Message.generateMeta(~service="ProfilePictureTask"),
          commandJson: User.UpdateProfilePicture(key)->User.command_encode,
        }
      ])
    ]->Promise.resolve
  } else {
    []->Promise.resolve
  }
}
```

### Document Processing Pipeline

```rescript
// Multi-stage document processing
let documentCallback = (~eventName, ~key) => {
  if eventName->Js.String2.includes("ObjectCreated") {
    [
      // Immediate processing
      PublishCommands("Document", [
        {
          Message.id: extractDocumentId(key),
          meta: Message.generateMeta(~service="DocumentTask"),
          commandJson: Document.StartProcessing(key)->Document.command_encode,
        }
      ]),
      // Scheduled follow-up
      CreateSchedule({
        name: `document-followup-${key}`,
        rate: Hours(24), // Check status after 24 hours
        payload: `{"documentKey": "${key}", "action": "checkStatus"}`,
      })
    ]->Promise.resolve
  } else {
    []->Promise.resolve
  }
}
```

### Batch Processing

```rescript
// Process files in batches
let batchCallback = (~eventName, ~key) => {
  if eventName->Js.String2.includes("ObjectCreated") {
    [
      // Add to batch queue
      PublishCommands("BatchProcessor", [
        {
          Message.id: "batch-queue",
          meta: Message.generateMeta(~service="BatchTask"),
          commandJson: BatchProcessor.AddToBatch(key)->BatchProcessor.command_encode,
        }
      ]),
      // Schedule batch processing if queue is full
      CreateSchedule({
        name: "process-batch",
        rate: Minutes(5), // Process batch every 5 minutes
        payload: `{"action": "processBatch"}`,
      })
    ]->Promise.resolve
  } else {
    []->Promise.resolve
  }
}
```

## Pulumi

The Task component is deployed as infrastructure that creates S3 buckets, Lambda functions, and event subscriptions. The actual file processing happens automatically when files are uploaded or modified.

```rescript
// Deployment creates all necessary infrastructure
module Task = Reventless.Task.Make(
  ProfilePictureTask,
  RuntimeEnvironment,
  EventCollectorChannel,
  EventCollectorRuntimeBuilder,
  TaskRuntimeBuilder,
  TaskBucket,
  SideEffectHandler,
)

let task = Task.make(
  ~queryBucketName,
  ~scheduler,
  ~publishToAggregates,
  ~queryEngine,
  ~allAggregates,
  ~opts=pulumiOpts,
)
```

## AWS Implementation

For detailed AWS-specific implementation including S3 bucket configuration, Lambda event subscriptions, IAM policies, and CORS settings, see [Task → Lambda + SQS](/aws/adapters/task).
