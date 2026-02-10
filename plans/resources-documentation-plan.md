# Resources Documentation Plan

## Overview
This plan outlines the documentation for the Resources page (`packages/doc/docs/inner-workings/resources.md`), which will explain how infrastructure resources are described and managed in the Reventless framework.

## Document Structure

### 1. Introduction
- **What are Resources in Reventless?**
  - Resources represent infrastructure components created by the framework
  - They serve as metadata descriptors for deployed AWS services
  - They bridge the gap between deploy-time (Pulumi) and runtime (Lambda) concerns

### 2. Resource Type Definition

#### Core Resource Type
Explain the `resource` type from [`Adapter.res`](packages/reventless-spec/src/adapter/Adapter.res:1-7):

```rescript
type resource = {
  name: Pulumi.Output.t<string>,      // Human-readable resource name
  id: Pulumi.Output.t<string>,        // AWS resource identifier (ARN, ID, etc.)
  urn: Pulumi.Output.t<string>,       // Pulumi URN for tracking
  info: Pulumi.Output.t<string>,      // Additional metadata
  service: Pulumi.Output.t<string>,   // AWS service type identifier
}
```

- **`name`**: Human-readable identifier for the resource
- **`id`**: AWS-specific identifier (e.g., DynamoDB table name, SQS queue URL, SNS topic ARN)
- **`urn`**: Pulumi's universal resource name for tracking and dependency management
- **`info`**: Additional metadata specific to the resource type
- **`service`**: AWS service type (e.g., "DynamoDb", "SQS", "SNS", "Lambda")

#### Resources Collection
Explain [`resources`](packages/reventless-spec/src/adapter/Adapter.res:9) type:
- `type resources = dict<resource>` - Dictionary of resources keyed by name
- Allows components to expose multiple related resources

### 3. Resource Lifecycle

#### Creation Phase (Deploy-time)
Show how resources are created during infrastructure provisioning:

**Example: EventLog Storage Resource**
```rescript
// From EventLogStorage_DynamoDb.res
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
```

Key points:
- Resources are created by adapter implementations (AWS-specific)
- Converted to the standard `resource` type via helper functions (`toResource`)
- Wrapped in `Pulumi.Output.t` for asynchronous resolution

#### Propagation Through Components
Show how resources flow through the component hierarchy:

```rescript
// From EventLog_Builder.res
let storage = Storage.make(~name, ~opts)

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

#### Usage Phase (Runtime)
Explain how resources are used at runtime:
- Resources provide runtime configuration (queue URLs, table names, etc.)
- Extracted from component outputs during Lambda handler setup
- Used to configure AWS SDK clients and operations

### 4. AWS Service Types

Document the supported AWS services from [`AWS.res`](packages/reventless-aws/src/adapter/AWS.res:3-16):

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

### 5. Resource Helper Functions

Document utility functions from [`Adapter.res`](packages/reventless/src/adapter/Adapter.res):

#### Unwrapped Resources
```rescript
type unwrappedResource = {
  name: string,
  id: string,
  urn: string,
  info: string,
  service: string,
}
```

Explain the purpose:
- Plain values without `Pulumi.Output.t` wrapping
- Used for runtime operations where all values are resolved
- Conversion functions: `resourceToUnwrappedOutput`, `unwrappedToResource`

#### Conversion Functions
- **`outputToResource`**: Convert a single output to resource
- **`resourcesOutputToResource`**: Extract first resource from array
- **`unwrappedToResource`**: Wrap plain values into resource
- **`unwrappedToResources`**: Batch wrap plain values
- **`resourcesToUnwrappedOutput`**: Convert resource array to unwrapped output
- **`urns`**: Extract URNs from unwrapped resources

### 6. Resource Filtering and Discovery

Show how resources are filtered by service type:

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

Explain use cases:
- Components need to discover specific resource types from dependencies
- Enables polymorphic infrastructure (e.g., EventTopic can use SNS or DynamoDbStream)
- Runtime handlers filter resources to find relevant AWS services

### 7. Common Patterns

#### Pattern 1: Component Output Resources
Every component exposes its resources in outputs:
```rescript
type outputs = {
  resources: array<resource>,
  // ... other outputs
}
```

#### Pattern 2: Resource Aggregation
Parent components aggregate child resources:
```rescript
// From Aggregate_Builder.res
let resources = [
  eventLog.resources,
  eventLog.eventTopic.resources
]->Array.flat
```

#### Pattern 3: Cross-Component Resource Passing
Resources enable communication setup between components:
```rescript
// EventCollector needs access to EventTopic resources to subscribe
let eventCollector = EventCollector.make(
  ~eventTopics,  // Contains resources for subscription setup
  ~opts,
)
```

#### Pattern 4: Runtime Resource Access
```rescript
// Resources provide runtime configuration
let queueUrl = (commandTopic.resources->Array.getUnsafe(0)).id
```

### 8. Best Practices

1. **Always Include Service Type**: Set the `service` field to identify the AWS service
2. **Meaningful Names**: Use descriptive names that reflect the component hierarchy
3. **Propagate Resources**: Pass resources to dependent components that need to interact with them
4. **Use Helper Functions**: Leverage conversion functions rather than manual transformation
5. **Filter Appropriately**: Use service-specific filters to find resources at runtime

### 9. Integration with Pulumi

Explain the relationship between resources and Pulumi:
- Resources wrap Pulumi's infrastructure primitives
- `urn` field links to Pulumi's state management
- `Pulumi.Output.t` ensures proper dependency resolution
- Resources enable Pulumi to track and manage infrastructure lifecycle

Reference the [Pulumi documentation](./pulumi.md) for more details on deploy-time concerns.

### 10. Examples

#### Example 1: Creating a DynamoDB Resource
Show complete flow from table creation to resource exposure

#### Example 2: Multi-Resource Component
Show how QueryDb exposes both storage and resolver resources

#### Example 3: Resource Filtering at Runtime
Show how EventCollector finds and uses SQS queue resources from EventTopics

### 11. Troubleshooting

Common issues and solutions:
- **Resource Not Found**: Ensure resources are properly propagated through component outputs
- **Type Mismatches**: Use conversion functions to switch between wrapped and unwrapped types
- **Missing Service Type**: Verify the `service` field is set correctly during resource creation
- **Array Index Errors**: Resources are arrays; use proper array access or filtering

### 12. Related Documentation

Links to related pages:
- [Component Structure Pattern](./component-structure-pattern.md) - How components organize resources
- [Pulumi Integration](./pulumi.md) - Deploy-time infrastructure management
- [Adapter Pattern](../reventless-components-overview.md) - Provider-specific implementations
- [AWS Lambda](./aws-lambda.md) - Runtime resource usage

## Diagrams to Include

### Diagram 1: Resource Lifecycle Flow
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

### Diagram 2: Resource Flow Through Components
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

### Diagram 3: Service Type Mapping
```
Component Type     →  Adapter Implementation  →  AWS Service
────────────────────────────────────────────────────────────
EventLog Storage   →  EventLogStorage_DynamoDb → DynamoDb
CommandTopic       →  CommandTopicChannel_SQS  → SQS/SQS_FIFO
EventTopic         →  EventTopicPublisher_SNS  → SNS/SNS_FIFO
QueryDb Storage    →  QueryDbStorage_DynamoDb  → DynamoDb
Task Bucket        →  TaskBucket_S3            → S3
```

## Documentation Style Guidelines

- Use code examples from actual framework code
- Include file path references as markdown links
- Provide both deploy-time and runtime perspectives
- Show complete, working examples
- Explain the "why" not just the "what"
- Cross-reference related documentation sections

## Key Messages to Convey

1. Resources are **metadata descriptors** for infrastructure, not the infrastructure itself
2. They provide a **standardized interface** across different AWS services
3. They enable **loose coupling** between components through dependency injection
4. They bridge **deploy-time and runtime** concerns
5. The `service` field enables **polymorphic infrastructure** (multiple adapter implementations)

## Questions to Address

1. How do resources differ from Pulumi's native resource types?
2. Why wrap everything in `Pulumi.Output.t`?
3. When should components expose resources vs. keep them internal?
4. How do resources enable component communication?
5. What's the relationship between `resource` and `unwrappedResource`?