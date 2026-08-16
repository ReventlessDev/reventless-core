---
title: StateChangeSlice
---

For a short summary of StateChangeSlice, see [Reventless Components Overview.](../component-overview.md)

:::info Framework Implementation
This component follows the Reventless [Component Structure Pattern](/framework/internals/component-structure-pattern), using separate files for interface definitions (`StateChangeSlice.res`), builder logic (`StateChangeSlice_Builder.res`), and callback/handler logic (`StateChangeSlice_Callback.res`).
:::

## Overview

```d2
Plugin: Plugin { class: plugin-area }
DcbEventLog: DcbEventLog { class: dcb-event-log }
CommandTopic: Command Topic { class: command-topic }
StateChangeSlice: StateChangeSlice { class: state-change-slice }

CommandTopic -> StateChangeSlice: commands { class: command-flow }
StateChangeSlice -> DcbEventLog: read/evolve { class: event-flow }
DcbEventLog -> StateChangeSlice: events { class: event-flow }
StateChangeSlice -> DcbEventLog: decide/append { class: event-flow }

Plugin -> DcbEventLog: creates
Plugin -> CommandTopic: creates
Plugin -> StateChangeSlice: creates
```

The **StateChangeSlice** is a DCB (Dynamic Consistency Boundary) component that processes commands against a shared event-sourced state. It implements a decision model pattern where commands are evaluated against accumulated events to produce new events or errors.

## Purpose and Responsibilities

- **Responsibility**: Process commands using a state (decision model) built from event history; append new events to the shared DcbEventLog; handle optimistic concurrency conflicts
- **In**: Commands from CommandTopic (routed by command type)
- **Out**: Events to DcbEventLog (via append operation)
- **Key Feature**: Multiple slices can coexist in a single plugin, each handling different command types but sharing the same event log

## Relationship with DCB

StateChangeSlice is a core component of the DCB architecture:

```d2
DCBArchitecture: DCB Architecture {
  class: plugin-area

  Client: Client { class: client }
  SQS: SQS Queue { class: aws-service }
  Lambda: DCB Lambda { class: aws-service }
  FilteringHandler: Filtering Handler
  Registry: Global Registry

  Slices: State Change Slices {
    class: slices-area
    Slice1: CreateItem Slice { class: state-change-slice }
    Slice2: RenameItem Slice { class: state-change-slice }
    SliceN: ...Slice N { class: state-change-slice }
  }

  DcbEventLog: DcbEventLog\nShared Event Log { class: dcb-event-log }

  Client -> SQS: commands { class: command-flow }
  SQS -> Lambda: messages
  Lambda -> FilteringHandler: routes to { class: command-flow }
  FilteringHandler -> Registry: looks up
  Registry -> Slices.Slice1: dispatches to { class: command-flow }
  Registry -> Slices.Slice2: dispatches to { class: command-flow }
  Registry -> Slices.SliceN: dispatches to { class: command-flow }

  Slices.Slice1 -> DcbEventLog: read/evolve/append { class: event-flow }
  Slices.Slice2 -> DcbEventLog: read/evolve/append { class: event-flow }
  Slices.SliceN -> DcbEventLog: read/evolve/append { class: event-flow }
}
```

## Component Spec

The StateChangeSlice component requires a spec that defines its name, command type, error type, and decision logic:

```rescript
module type Spec = {
  let name: string

  // Local subset of events this slice reads to rebuild its decision state.
  // Declared locally — there is no shared DcbEventLogSpec module.
  @schema
  type consumedEvent

  @schema
  type command

  @schema
  type error

  // Events this slice emits from `decide`.
  @schema
  type event

  type state
  let initialState: state
  let evolve: (state, consumedEvent) => state
  let decide: (state, command) => result<array<event>, error>
}
```

### Spec Fields Explained

| Field | Type | Description |
|-------|------|-------------|
| `name` | `string` | Unique identifier for this slice |
| `consumedEvent` | `@schema type` | Local subset of events this slice reads to build its decision state |
| `command` | `@schema` [type](../rescript-syntax.md#ppx) | Command type using `@schema` [ppx](../rescript-syntax.md#ppx) for auto-generated schema |
| `error` | `@schema type` | Error type for command processing failures |
| `event` | `@schema type` | Events this slice emits from `decide` |
| `state` | `type` | The state type built from accumulated events |
| `initialState` | `state` | Starting state for new aggregates/entities |
| `evolve` | `(state, event) => state` | Fold function to accumulate events into state |
| `decide` | `(state, command) => result<events, error>` | Business logic to produce events from command |

## Runtime Behavior

### Command Processing Flow

```d2
shape: sequence_diagram

CommandTopic: CommandTopic { class: command-topic }
StateChangeSlice: StateChangeSlice
DcbEventLog: DcbEventLog { class: dcb-event-log }
Storage: DynamoDB { class: aws-service }

CommandTopic -> StateChangeSlice: "handleCommands(commands)"
StateChangeSlice -> StateChangeSlice: "Build query from command schema"
StateChangeSlice -> DcbEventLog: "readStream(~query)"
DcbEventLog -> Storage: Query events by tags
Storage --> DcbEventLog: events
StateChangeSlice -> StateChangeSlice: "evolve(events) → state"
StateChangeSlice -> StateChangeSlice: "decide(state, command)"
StateChangeSlice -> DcbEventLog: "append(events, ~condition)"
DcbEventLog -> Storage: "Write events (conditional)"
Storage --> DcbEventLog: position
StateChangeSlice --> CommandTopic: results array
```

### Optimistic Concurrency Control

StateChangeSlice implements optimistic concurrency to handle concurrent command processing:

```rescript
// The callback reads the current head position
let readResult = await dcbEventLog.read(~query)

// Uses the position as a condition for append
let condition: DcbTag.appendCondition = {
  query,
  after: ?readResult.headPosition,
}

// If another process appended between read and write, retry
switch await dcbEventLog.append(newEvents, ~condition) {
| Ok(position) => // Success
| Error(err) =>
  if retries > 0 {
    // Retry with fresh read
    await attempt(~retries=retries - 1)
  } else {
    // Exhausted retries
    Error("conflict: retries exhausted")
  }
}
```

**Key points:**
- Reads event log state before processing
- Records `headPosition` (sequence position of last event)
- Uses conditional append: only succeeds if no events were added after `headPosition`
- Retries up to 3 times on conflict
- Provides detailed logging for debugging

### Automatic Query Construction

The query is built automatically from the command schema via `DcbTag.buildQueryFromCommand`:

- **Scalar tagged fields** (e.g., `itemId: string` auto-tagged by PPX) — all tags go into a single AND clause (single-entity query)
- **Tagged array fields** (e.g., `productId: array<string>` auto-tagged on elements) — each element becomes its own OR clause (cross-entity query)

No configuration is needed — the schema determines the query mode automatically.

When a variant has multiple `*Id` fields, use `@partitionTag` on the field that should be the partition key, or `@compositePartitionTag` on multiple fields to form a composite key joined in declaration order — see [PPX annotations](../rescript-syntax.md#reventless-ppx-annotations).

## Error Handling

### Error Types

StateChangeSlice defines error types for business logic failures:

```rescript
@schema
type error =
  | ItemNotFound
  | ItemAlreadyExists
  | InsufficientStock(int)  // With payload
  | ValidationError(string)
```

### Error Processing

Errors are:
1. Returned from the `decide` function
2. Logged with full context (slice name, command, error details)
3. Converted to JSON using the error schema
4. Passed back to the caller via CommandTopic reference

```rescript
| Error(error) =>
  let errorJson = error->S.reverseConvertToJsonOrThrow(Spec.errorSchema)->JSON.stringify
  Logger.error(~loc=__LOC__, `StateChangeSlice(${Spec.name}): decide error`, errorJson)
  Error(errorJson)
```

### Conflict Resolution

When concurrent modifications cause conflicts:

```rescript
| Error(err) =>
  if retries > 0 {
    Logger.info(~loc=__LOC__, `StateChangeSlice(${Spec.name}): conflict, retrying`, err)
    await attempt(~retries=retries - 1)
  } else {
    Logger.error(
      ~loc=__LOC__, 
      `StateChangeSlice(${Spec.name}): conflict, retries exhausted`, 
      err,
    )
    Error("conflict: retries exhausted")
  }
```

## DCB Tags

StateChangeSlice uses DCB tags for efficient event queries. In slice files the PPX auto-injects `@s.matches(DcbTag.string)` on all `*Id: string` fields — no manual annotation needed:

```rescript
// In a StateChangeSlice file — PPX auto-tags *Id fields
@schema
type command =
  | CreateItem({itemId: string, name: string})
  | RenameItem({itemId: string, newName: string})
```

The DCB tag:
1. Marks the field as a DCB query key
2. Automatically extracts tag values from commands at runtime
3. Enables efficient querying of relevant events from DcbEventLog

### Multiple `*Id` fields — partition key

When a variant has multiple `*Id` fields, use `@partitionTag` to mark which one is the partition key:

```rescript
@schema
type event =
  | DemandRecorded({
      @partitionTag productId: string,  // partition key
      orderId: string,                  // also tagged as DcbTag.string
    })
```

### Composite partition keys

When the partition key should be derived from **multiple fields joined in declaration order**, use `@compositePartitionTag`. Each annotated field is still individually queryable as a regular tag:

```rescript
@schema
type event =
  | PluginSynced({
      @compositePartitionTag environment: string,   // "/"  after (default)
      @compositePartitionTag platformName: string,  // "/"  after
      @compositePartitionTag pluginName: string,    // last — sep ignored
      version: string,
    })
// Partition key: e.g. "prod/acme-platform/billing"
```

Use `@compositePartitionTag(":")` to set a different separator after a field. Cannot be combined with `@partitionTag` on the same schema.

### Cross-Entity Queries with Tagged Arrays

When a command references multiple entities, use a `*Id: array<string>` field (singular name). Inside a `StateChangeSlice/` folder the PPX auto-applies `@s.matches(Reventless.DcbTag.string)` to the element type:

```rescript
@schema
type command =
  | PlaceOrder({
      orderId: string,                  // tagged automatically
      productId: array<string>,         // elements tagged automatically
    })
```

For a plural-named field (`productIds: array<string>`) the PPX strips the trailing `s` and tags the elements under key `productId`, so a multi-value field shares a tag key with the singular-named producers.

The runtime automatically detects tagged array fields and builds multi-clause OR queries — one clause per scalar tag, one per array element. This fetches events for all referenced entities into the same state, enabling cross-entity validation at command time.

**Key rule:** name the array field to match the tag key on the referenced events (e.g., command field `productId` matches the `productId` tag on `CatalogProductSynced` events).

## Best Practices

### 1. Keep Decision Models Focused

```rescript
// Good: Focused on specific domain concern
type state = {
  active: bool,
  lastActivity: option<Js.Date.t>,
}

// Avoid: Bloated models trying to handle everything
type state = {
  // ... 50+ fields for unrelated concerns
}
```

### 2. Match `consumedEvent` Exhaustively in `evolve`

```rescript
// consumedEvent lists exactly the variants this slice reads,
// so evolve matches them all — no catch-all needed.
let evolve = (state, event) =>
  switch event {
  | KnownEvent1 => state // handle
  | KnownEvent2 => state // handle
  }
```

### 3. Idempotent Commands

Design commands to be idempotent when possible. A command that produces no state change should return `Ok([])`, not an error — commands may be retried under at-least-once delivery:

```rescript
let decide = (state, command) =>
  switch command {
  | SetName({id, name}) =>
    if name == state.name {
      Ok([]) // idempotent — name unchanged, emit nothing
    } else {
      Ok([NameSet({id, name})])
    }
  }
```

### 4. Tag Only What's Needed

DCB tags are auto-applied to `*Id` fields inside `StateChangeSlice/` folders. For a payload field that happens to end in `Id` but is **not** a query key, suppress tagging with `@noDcbTag`:

```rescript
// Good: *Id fields are tagged automatically; suppress the ones that are payload only
@schema
type command = CreateItem({
  itemId: string,            // auto-tagged for entity lookup
  @noDcbTag externalId: string,  // payload data, not a DCB query key
})
```

## Pulumi Outputs

```rescript
type outputs = {
  resources: array<Reventless.Adapter.resource>,
}
```

The StateChangeSlice reuses resources from the shared DcbEventLog:
- DynamoDB table for event storage
- SNS topic for event publishing
- Related IAM roles and policies

## Related Components

- **[DcbEventLog](/framework/runtime-components/dcbeventlog)** - Shared event log for DCB slices
- **[CommandTopic](/framework/runtime-components/commandtopic)** - Command routing and filtering
- **[Plugin](./plugin.md)** - Hosts DCB slices and creates shared infrastructure
- **[EventCollector](/framework/runtime-components/eventcollector)** - Consumes events from DcbEventLog
- **[ReadModel](./readmodel.md)** - Builds read models from DcbEventLog events

## AWS Implementation

For detailed implementation with AWS services (DynamoDB for storage, SNS for publishing, SQS for commands), see [StateChangeSlice AWS Adapter Documentation](/infrastructure/aws/adapters/statetopic) (reuses EventLog infrastructure).
