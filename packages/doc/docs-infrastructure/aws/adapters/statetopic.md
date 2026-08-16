---
title: "StateTopic → DynamoDB + DynamoDB Streams"
---

## StateTopic → DynamoDB Streams

The StateTopic adapter enables publishing state changes from Read Models by connecting to DynamoDB Streams, allowing other components to react to changes in query database tables without explicit publish calls.

## How StateTopic Works

StateTopic provides a declarative way to expose Read Model state changes as events:

1. **Read Model** updates its QueryDb (DynamoDB table) with new/changed state
2. **DynamoDB Streams** captures the change as a stream record
3. **StateTopic Publisher** exposes the stream as a Reventless resource
4. **Downstream components** can subscribe to the stream for state change notifications

This pattern enables event-driven architectures where Read Models become event sources themselves, not just event consumers.

## Deploy-time Configuration

The StateTopic adapter creates a publisher that exposes a DynamoDB Stream as a subscribable resource:

```rescript
let make: Reventless.StateTopic.Adapter.publisherMaker = (~name, ~opts as _, ~allQueryDbs) => {
  let queryDbResource =
    allQueryDbs
    ->Reventless.Util.ReadModel.queryDbStorageResources(
      name->Js.String2.substring(
        ~from=0,
        ~to_=name->Js.String2.indexOf(ReadModel->Reventless.ComponentType.toName),
      ),
    )
    ->Util.DynamoDbStream.findResource

  {
    resource: queryDbResource.service
    ->Pulumi.Output.apply(service =>
      if service == AWS.DynamoDbStream.service {
        queryDbResource->Util_DynamoDbStream.toStreamResource
      } else {
        Js.Exn.raiseError(
          "StateTopicPublisher_DynamoDbStream cannot connect to QueryDbStorage_" ++ service,
        )
      }
    )
    ->Reventless.Adapter.outputToResource,
  }
}
```

**Deploy-time setup:**

- **Query database resolution** - Finds the QueryDb resource for the associated Read Model by name
- **Stream extraction** - Extracts the DynamoDB Stream from the table resource
- **Service validation** - Ensures the QueryDb uses DynamoDB Streams (fails if not)
- **Resource wrapping** - Wraps the stream as a Reventless adapter resource for dependency tracking

**Key characteristics:**

- **Pure deploy-time** - StateTopic has no runtime operations; it only exposes infrastructure
- **Read Model coupling** - Tightly coupled to a specific Read Model's QueryDb
- **Name-based resolution** - Uses naming conventions to find the correct QueryDb
- **Type safety** - Validates at deploy-time that the QueryDb supports streams

## Runtime Behavior

Unlike other adapters, StateTopic has **no runtime operations** - it's a pure deploy-time resource:

- **No publish API** - State changes are published automatically via DynamoDB Streams
- **No explicit calls** - Components subscribe to the stream directly
- **Passive publisher** - The QueryDb table's stream is the event source

**Subscription pattern:**

```rescript
// Other components can subscribe to the stream
let eventSourceMapping = PulumiAws.Lambda.EventSourceMapping.make(
  ~name="ProcessUserStateChanges",
  ~args={
    eventSourceArn: stateTopicResource.urn,
    functionName: handlerLambda.name,
    startingPosition: "LATEST",
  },
)
```

**Stream record format:**

DynamoDB Stream records contain:
- **NewImage** - The new state of the item (for INSERT and MODIFY)
- **OldImage** - The previous state (for MODIFY and REMOVE)
- **Keys** - The primary key values
- **EventName** - INSERT, MODIFY, or REMOVE

## Use Cases

**Materialized view chains:**
```rescript
// Read Model 1: UserProfile (source)
// StateTopic: UserProfileStateChanges
// Read Model 2: UserStatistics (derived from UserProfile changes)
```

**Cross-aggregate reactions:**
```rescript
// Read Model: InventoryLevels (tracks stock)
// StateTopic: InventoryStateChanges
// Extension: LowStockAlerts (reacts to inventory drops)
```

**Audit logging:**
```rescript
// Read Model: SensitiveData (primary storage)
// StateTopic: DataAccessLog
// Logger: AuditTrail (records all state changes)
```

**State synchronization:**
```rescript
// Read Model: CachedData (primary cache)
// StateTopic: CacheInvalidation
// Secondary Cache: Invalidates on state changes
```

**Key advantages:**

- **Zero-overhead publishing** - No explicit publish calls needed
- **Change Data Capture (CDC)** - Automatic capture of all table changes
- **Event sourcing from state** - Bridge state-based and event-based architectures
- **Decoupling** - Read Models don't need to know about downstream consumers
- **Stream guarantees** — DynamoDB Streams deliver records in order per shard, at least once; a consumer must tolerate a repeat

**When to use StateTopic:**

- Need to expose Read Model state changes as events
- Want to build derived Read Models from other Read Models
- Implementing change data capture patterns
- Bridging state-based and event-driven components
- Don't want to add explicit publish logic to Read Models

**When NOT to use StateTopic:**

- Need domain events (use EventTopic instead)
- Want explicit control over what events are published
- Require event schemas different from database schema
- Don't want DynamoDB Streams overhead on your table

