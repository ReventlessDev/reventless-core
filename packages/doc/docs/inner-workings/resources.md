---
title: Resources
date: 2024-08-28
draft: false
---

# Resources

Resources in Reventless represent infrastructure components created by the framework. They serve as metadata descriptors for deployed AWS services and bridge the gap between deploy-time (Pulumi) and runtime (Lambda) concerns.

## What are Resources in Reventless?

Resources are **metadata descriptors** for infrastructure, not the infrastructure itself. They provide a standardized interface across different AWS services, enable loose coupling between components through dependency injection, and bridge deploy-time and runtime concerns.

Key characteristics:
- Resources represent infrastructure components created by the framework
- They serve as metadata descriptors for deployed AWS services  
- They bridge the gap between deploy-time (Pulumi) and runtime (Lambda) concerns
- The `service` field enables polymorphic infrastructure (multiple adapter implementations)

## Resource Type Definition

### Core Resource Type

The [`resource`](packages/reventless-spec/src/adapter/Adapter.res:1-7) type from Adapter.res defines the standard structure:

```rescript
type resource = {
  name: Pulumi.Output.t<string>,      // Human-readable resource name
  id: Pulumi.Output.t<string>,        // AWS resource identifier (ARN, ID, etc.)
  urn: Pulumi.Output.t<string>,       // Pulumi URN for tracking
  info: Pulumi.Output.t<string>,      // Additional metadata
  service: Pulumi.Output.t<string>,   // AWS service type identifier
}
```

**Field Descriptions:**
- **`name`**: Human-readable identifier for the resource
- **`id`**: AWS-specific identifier (e.g., DynamoDB table name, SQS queue URL, SNS topic ARN)
- **`urn`**: Pulumi's universal resource name for tracking and dependency management
- **`info`**: Additional metadata specific to the resource type
- **`service`**: AWS service type (e.g., "DynamoDb", "SQS", "SNS", "Lambda")

### Resources Collection

The [`resources`](packages/reventless-spec/src/adapter/Adapter.res:9) type is defined as:
```rescript
type resources = dict<resource>
```

This dictionary structure allows components to expose multiple related resources, keyed by name.

## Resource Lifecycle

### Creation Phase (Deploy-time)

Resources are created during infrastructure provisioning by adapter implementations. Here's an example from EventLog Storage:

**Example: EventLog Storage Resource**
```rescript
// From EventLogStorage_DynamoDb.res
let make: Reventless.EventLog_Adapter.storageMaker = (~name, ~opts) => {
  let table = Util.DynamoDb.makeTable(
    name,
    ~attributes=[{name: "id", type_: "S"}, {name: "sequenceNr", type_: "S"}],
    ~rangeKey="sequenceNr",
    ~tags=AWS.Tags.make(~name, Reventless.EventLog.componentType),
    ~opts,
  )

  {
    resources: [table->Util_DynamoDb.toResource],
    operations: // ... runtime operations
  }
}
```

**Key points:**
- Resources are created by adapter implementations (AWS-specific)
- Converted to the standard `resource` type via helper functions (`toResource`)
- Wrapped in `Pulumi.Output.t` for asynchronous resolution

### Propagation Through Components

Resources flow through the component hierarchy, enabling communication setup between components:

```rescript
// From EventLog_Builder.res
let storage = Storage.make(~name, ~opts)

module SpecificEventTopic = EventTopic_Builder.Make(Spec, EventTopicPublisher)
let eventTopic = SpecificEventTopic.make(
  ~name,
  ~storageResources=storage.resources,  // Resources passed to dependent components
  ~opts,
)

self->Component.setOutputs({
  EventLog.resources: storage.resources,  // Resources exposed in component outputs
  eventTopic: eventTopic->Component.outputs,
})
```

### Usage Phase (Runtime)

At runtime, resources provide configuration for AWS SDK clients:
- Resources provide runtime configuration (queue URLs, table names, etc.)
- Extracted from component outputs during Lambda handler setup
- Used to configure AWS SDK clients and operations

Example runtime usage:
```rescript
// Resources provide runtime configuration
let queueUrl = (commandTopic.resources->Array.getUnsafe(0)).id
```

## AWS Service Types

The framework supports multiple AWS services, defined in [`AWS.res`](packages/reventless-aws/src/adapter/AWS.res:3-16):

| Service Type | Description | Used By |
|-------------|-------------|---------|
| **DynamoDb** | NoSQL database tables | EventLog storage, QueryDb storage |
| **DynamoDbStream** | Change data capture streams | EventTopic publisher, EventCollector channel |
| **SQS** | Standard message queues | CommandTopic, EventCollector |
| **SQS_FIFO** | FIFO message queues | CommandTopic (ordered), EventCollector (ordered) |
| **SNS** | Pub/sub messaging topics | EventTopic publisher |
| **SNS_FIFO** | FIFO pub/sub topics | EventTopic publisher (ordered) |
| **Lambda** | Serverless functions | All runtime handlers |
| **AppSync** | GraphQL API | CommandGenerator, QueryDb resolvers |
| **IAM** | Identity and access management | Roles and policies for all components |
| **CloudwatchEventRule** | Scheduled events | Heartbeat runner |
| **S3** | Object storage | Task buckets |
| **Kinesis** | Streaming data | (Future use) |

Each service module provides:
- `service`: String identifier for the service type
- `principal`: AWS service principal for IAM policies

## Resource Helper Functions

The [`Adapter.res`](packages/reventless/src/adapter/Adapter.res) file provides utility functions for working with resources:

### Unwrapped Resources

```rescript
type unwrappedResource = {
  name: string,
  id: string,
  urn: string,
  info: string,
  service: string,
}
```

**Purpose:**
- Plain values without `Pulumi.Output.t` wrapping
- Used for runtime operations where all values are resolved
- Conversion functions: `resourceToUnwrappedOutput`, `unwrappedToResource`

### Conversion Functions

Key conversion functions include:
- **`outputToResource`**: Convert a single output to resource
- **`resourcesOutputToResource`**: Extract first resource from array
- **`unwrappedToResource`**: Wrap plain values into resource
- **`unwrappedToResources`**: Batch wrap plain values
- **`resourcesToUnwrappedOutput`**: Convert resource array to unwrapped output
- **`urns`**: Extract URNs from unwrapped resources

## Resource Filtering and Discovery

Components can filter resources by service type to discover specific resource types from dependencies:

From [`Adapter_Helpers.res`](packages/reventless-aws/src/adapter/Adapter_Helpers.res):
```rescript
let dynamoDbResources = resources =>
  resources->filterSupportedUnwrappedResources([
    AWS.DynamoDb.service,
    AWS.DynamoDbStream.service,
  ])

let sqsResources = resources =>
  resources->filterSupportedUnwrappedResources([
    AWS.SQS.service,
    AWS.SQS_FIFO.service,
  ])
```

**Use cases:**
- Components need to discover specific resource types from dependencies
- Enables polymorphic infrastructure (e.g., EventTopic can use SNS or DynamoDbStream)
- Runtime handlers filter resources to find relevant AWS services

## Common Patterns

### Pattern 1: Component Output Resources
Every component exposes its resources in outputs:
```rescript
type outputs = {
  resources: array<resource>,
  // ... other outputs
}
```

### Pattern 2: Resource Aggregation
Parent components aggregate child resources:
```rescript
// From Aggregate_Builder.res
let resources = [
  eventLog.resources,
  eventLog.eventTopic.resources
]->Array.flat
```

### Pattern 3: Cross-Component Resource Passing
Resources enable communication setup between components:
```rescript
// EventCollector needs access to EventTopic resources to subscribe
let eventCollector = EventCollector.make(
  ~eventTopics,  // Contains resources for subscription setup
  ~opts,
)
```

### Pattern 4: Runtime Resource Access
```rescript
// Resources provide runtime configuration
let queueUrl = (commandTopic.resources->Array.getUnsafe(0)).id
```

## Best Practices

1. **Always Include Service Type**: Set the `service` field to identify the AWS service
2. **Meaningful Names**: Use descriptive names that reflect the component hierarchy
3. **Propagate Resources**: Pass resources to dependent components that need to interact with them
4. **Use Helper Functions**: Leverage conversion functions rather than manual transformation
5. **Filter Appropriately**: Use service-specific filters to find resources at runtime

## Integration with Pulumi

Resources have a close relationship with Pulumi's infrastructure management:
- Resources wrap Pulumi's infrastructure primitives
- `urn` field links to Pulumi's state management
- `Pulumi.Output.t` ensures proper dependency resolution
- Resources enable Pulumi to track and manage infrastructure lifecycle

Reference the [Pulumi documentation](./pulumi.md) for more details on deploy-time concerns.

## Examples

### Example 1: Creating a DynamoDB Resource

Complete flow from table creation to resource exposure:

```rescript
// 1. Create the DynamoDB table using Pulumi
let table = Util.DynamoDb.makeTable(
  name,
  ~attributes=[{name: "id", type_: "S"}, {name: "sequenceNr", type_: "S"}],
  ~rangeKey="sequenceNr",
  ~tags=AWS.Tags.make(~name, Reventless.EventLog.componentType),
  ~opts,
)

// 2. Convert to standard resource format
let resource = table->Util_DynamoDb.toResource

// 3. Expose in component outputs
{
  resources: [resource],
  operations: // ... runtime operations
}
```

### Example 2: Multi-Resource Component

QueryDb exposes both storage and resolver resources:

```rescript
// Storage resource (DynamoDB table)
let storageResource = table->Util_DynamoDb.toResource

// Resolver resource (AppSync function)
let resolverResource = resolver->Util_AppSync.toResource

// Expose both resources
{
  resources: [storageResource, resolverResource],
  operations: // ... runtime operations
}
```

### Example 3: Resource Filtering at Runtime

EventCollector finds and uses SQS queue resources from EventTopics:

```rescript
// Filter for SQS resources from event topics
let sqsQueues = eventTopicResources->sqsResources

// Use the first SQS queue for message processing
let queueUrl = switch sqsQueues->Array.get(0) {
| Some(queue) => queue.id
| None => // Handle no SQS resources found
}
```

## Troubleshooting

Common issues and solutions:

- **Resource Not Found**: Ensure resources are properly propagated through component outputs
- **Type Mismatches**: Use conversion functions to switch between wrapped and unwrapped types
- **Missing Service Type**: Verify the `service` field is set correctly during resource creation
- **Array Index Errors**: Resources are arrays; use proper array access or filtering

## Resource Lifecycle Flow

```
Deploy-time                        Runtime
┌─────────────────────────┐       ┌──────────────────────┐
│ Pulumi Infrastructure   │       │ Lambda Handler       │
│                         │       │                      │
│ AWS Service Creation    │       │ Extract Resource ID  │
│        ↓                │       │        ↓             │
│ toResource()            │       │ Configure AWS SDK    │
│        ↓                │       │        ↓             │
│ Component Outputs       │──────→│ Execute Operations   │
│        ↓                │       │                      │
│ Resource Propagation    │       │                      │
└─────────────────────────┘       └──────────────────────┘
```

## Resource Flow Through Components

```
EventLog Component
├── Storage (DynamoDB)
│   └── resources: [dynamodb-table-resource]
│
└── EventTopic
    ├── storageResources (from Storage)
    └── Publisher (SNS)
        └── resources: [sns-topic-resource]

Aggregate Component
└── EventLog
    └── Aggregated resources: [dynamodb-table, sns-topic]
```

## Service Type Mapping

```
Component Type     →  Adapter Implementation  →  AWS Service
────────────────────────────────────────────────────────────
EventLog Storage   →  EventLogStorage_DynamoDb → DynamoDb
CommandTopic       →  CommandTopicChannel_SQS  → SQS/SQS_FIFO
EventTopic         →  EventTopicPublisher_SNS  → SNS/SNS_FIFO
QueryDb Storage    →  QueryDbStorage_DynamoDb  → DynamoDb
Task Bucket        →  TaskBucket_S3            → S3
```

## Related Documentation

Links to related pages:
- [Component Structure Pattern](./component-structure-pattern.md) - How components organize resources
- [Pulumi Integration](./pulumi.md) - Deploy-time infrastructure management
- [Adapter Pattern](../reventless-components-overview.md) - Provider-specific implementations
- [AWS Lambda](./aws-lambda.md) - Runtime resource usage

## Questions Addressed

1. **How do resources differ from Pulumi's native resource types?**
   Resources provide a standardized abstraction layer over Pulumi resources, with consistent field structure across all AWS services.

2. **Why wrap everything in `Pulumi.Output.t`?**
   This ensures proper dependency resolution during infrastructure deployment and allows for asynchronous value resolution.

3. **When should components expose resources vs. keep them internal?**
   Expose resources when other components need to interact with them (e.g., EventTopic resources for EventCollector subscription).

4. **How do resources enable component communication?**
   Resources provide the necessary identifiers (URLs, ARNs, names) for components to connect to each other's infrastructure.

5. **What's the relationship between `resource` and `unwrappedResource`?**
   `unwrappedResource` contains plain string values for runtime use, while `resource` wraps values in `Pulumi.Output.t` for deploy-time dependency management.
