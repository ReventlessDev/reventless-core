---
title: Messages
date: 2024-08-13
draft: false
---

# Messages in Reventless

Messages are the fundamental communication mechanism in the reventless event-sourcing framework. They enable decoupled, scalable systems by providing structured ways to express intent (commands) and facts (events) while maintaining traceability and correlation across distributed services.

## Introduction & Conceptual Overview

### What are Messages in Event-Sourcing?

In event-sourcing architecture, messages serve as the primary means of communication between different parts of the system. They represent either:

- **Commands**: Intent to change state ("I want to create a customer")
- **Events**: Immutable facts about what happened ("Customer was created")

Messages in reventless carry not just the payload data, but also essential metadata for distributed tracing, correlation, and system observability.

### How Messages Enable Decoupled, Scalable Systems

Messages provide several key benefits:

1. **Temporal Decoupling**: Producers and consumers don't need to be online simultaneously
2. **Spatial Decoupling**: Services don't need to know about each other's locations
3. **Synchronization Decoupling**: Operations can be asynchronous
4. **Failure Isolation**: One service's failure doesn't cascade to others

### The Journey from Command to Event

The typical message flow in reventless follows this pattern:

1. **Client** sends a `command'` to express intent
2. **Aggregate** processes the command and produces `event'` instances
3. **EventLog** persists the events for durability
4. **EventTopic** publishes events to interested subscribers
5. **ReadModels** consume events to update their projections

### Message Types Overview

Reventless defines several core message types:

- **`meta`**: Metadata for tracing and correlation
- **`context`**: Command processing context
- **`event'<'id, 'event>`**: Structured event with metadata
- **`command'<'id, 'command>`**: Structured command with metadata
- **`commandJson`**: Serialized command for transport

## Core Message Types

### Meta Type (`meta`)

The `meta` type provides envelope metadata for every message in the system. It is **shared** by both `event'` and `command'` envelopes — fields are kept generic so they apply equally to commands and events.

```rescript
type meta = {
  service: service,         // producer service name
  time: string,             // ISO-8601 producer timestamp
  ip?: string,              // producer IP — absent when unknown (e.g. serverless)
  user?: string,            // acting user — absent for system-initiated messages
  msgId: string,            // unique id of this message
  correlationId: string,    // root id of the correlation chain (defaults to msgId)
  causationId?: string,     // id of the *direct* parent that caused this message
  traceparent?: string,     // W3C Trace Context header, opaque pass-through
  schemaVersion?: string,   // schema version of this message's payload variant
  headers?: dict<string>,   // extensible bag (tenantId, feature flags, etc.)
}
```

**Field semantics**:
- `service` / `time` / `msgId` are always present.
- `correlationId` is always present; defaults to `msgId` when this message is the chain root.
- `causationId` identifies the **direct** parent (the immediately preceding message in the chain); absent at the chain root. Together with `correlationId` this gives you both "the whole chain root" and "my parent" — enough to reconstruct the full causation graph.
- `traceparent` is stored under that exact lowercase spelling because it is the literal W3C Trace Context HTTP header name, used verbatim by OpenTelemetry SDKs and AWS X-Ray. Adapters do zero case-translation between the HTTP header and the meta field.
- `ip` / `user` are `option<string>` — *absent* means "unknown" / "system". There are no `""` / `"unknown"` sentinel values to special-case.
- `headers` is an extensible string-keyed bag for cross-cutting context (tenant id, feature flags, request-scoped state); absent when empty. Read it with `meta.headers->Option.getOr(Dict.make())`.

#### `meta.time` (producer time) vs `recordedAt` (storage time)

A message carries **two distinct clocks**, and they are not interchangeable:

| | `meta.time` | `recordedAt` |
|---|---|---|
| **Who sets it** | the *producer* — the command handler, when it creates the event | the *storage adapter*, when it appends the event to the log |
| **When** | at message creation | at append, after the message already exists |
| **Lives on** | `meta` — inside every `event'` **and** `command'` | the storage record only (`StoredEvent`, `DcbEventLog.rawSequencedEvent`), **never** on `meta` |
| **Use for** | domain-meaningful timestamps (order placed, shipment sent), audit trails | storage-lag diagnostics, replay ordering sanity |

`recordedAt` is deliberately **not** a `meta` field. `meta` is the producer envelope, shared byte-for-byte by commands and events; a command is never stored, so it has no `recordedAt`. Folding storage time into `meta` would both break that shared command/event contract and put the two clocks side by side under names that invite confusion. Instead `recordedAt` sits as a top-level sibling of `meta` on the storage record types — the same place it appears on the `StateViewSlice.consumed<'e>` projection envelope (`{event, meta, recordedAt}`).

One caveat on `recordedAt`'s provenance across delivery paths: on the AWS (DynamoDB-stream) path and the SQLite catch-up path it is the authoritative stored value; on the in-memory local topic path it is stamped at publish (a few milliseconds after the stored value), because the append call returns only the position, not the stamp. Domain code should key off `meta.time`, which is identical on every path.

**Building meta**:
- `Message.generateMeta(~service, ~ip=?, ~user=?, ~causationId=?, ~traceparent=?, ~correlationId=?, ~schemaVersion=?, ~headers=?)` — root meta for messages starting a new chain.
- `Message.deriveMeta(~parent, ~service=?)` — child meta for messages emitted in response to a triggering message. Sets `causationId = parent.msgId`, inherits `correlationId` (so the chain root id stays stable), inherits `ip` / `user` / `traceparent` / `schemaVersion` / `headers`, and produces a fresh `msgId` + `time`. The framework uses this in `Aggregate_Callback`, `StateChangeSlice_Callback`, `EventMapper_Callback`, and `Extension_Operations.forwardCommand`.

**Purpose**:
- **Distributed Tracing**: Track messages across service boundaries; `traceparent` hands off to OpenTelemetry / X-Ray.
- **Causation Graph**: `causationId` (direct parent) + `correlationId` (chain root) reconstruct the full message graph.
- **Audit Trails**: Maintain a complete history of who did what when.
- **Multi-tenant Routing**: `headers.tenantId` is the conventional slot for tenant context.

### Context Type (`context`)

The `context` type provides processing context to command handlers.

```rescript
type context = {
  id: string,
  meta: meta,
}
```

**Purpose**:
- Provide aggregate ID and metadata to command handlers
- Enable aggregates to access correlation information
- Support audit and tracing within aggregate processing

**Usage Patterns**:
- Passed to aggregate command handlers
- Contains the target aggregate ID
- Carries forward the original message metadata

### Event' Type (`event'<'id, 'event>`)

The `event'` type represents structured events with full metadata.

```rescript
type event'<'id, 'event> = {
  id: 'id,           // aggregate or entity identifier
  meta: meta,        // message metadata
  event: 'event,     // the actual event payload
}
```

**Purpose**:
- Represent immutable facts about what happened in the system
- Carry complete context for event processing
- Enable event replay and projection building

**Usage Patterns**:
- Produced by aggregates after successful command processing
- Stored in event logs for persistence
- Published to event topics for consumption by read models
- Used in event replay scenarios

### Command' Type (`command'<'id, 'command>`)

The `command'` type represents structured commands with metadata.

```rescript
type command'<'id, 'command> = {
  id: 'id,           // target aggregate identifier
  meta: meta,        // message metadata
  command: 'command, // the actual command payload
}
```

**Purpose**:
- Express intent to change system state
- Carry routing information (target aggregate ID)
- Maintain traceability from command to resulting events

**Usage Patterns**:
- Created by clients or other services
- Routed to appropriate aggregates based on ID
- Validated and processed by command handlers
- Generate events upon successful processing

### CommandJson Type (`commandJson`)

The `commandJson` type represents serialized commands for transport.

```rescript
type commandJson = {
  id: string,             // target aggregate identifier as string
  meta: meta,             // message metadata
  commandJson: Js.Json.t, // serialized command payload
  delay?: int,            // optional delay in milliseconds
}
```

**Purpose**:
- Enable command transport over message queues
- Support delayed command execution
- Provide schema-agnostic command serialization

**Usage Patterns**:
- Used in message queue implementations
- Supports command scheduling with delay
- Enables cross-service command routing

## Message Flow Patterns

### Command-to-Event Flow

The fundamental flow pattern in reventless shows how commands transform into events:

```d2
Client: Client { class: client }
CT: CommandTopic { class: command-topic }
Agg: Aggregate { class: aggregate }
EL: EventLog { class: event-log }
ET: EventTopic { class: event-topic }
RM: ReadModel { class: read-model }

Client -> CT: command' { class: command-flow }
CT -> Agg: command' { class: command-flow }
Agg -> EL: "event'[]" { class: event-flow }
EL -> ET: "event'[]" { class: event-flow }
ET -> RM: event' { class: event-flow }
```

This flow demonstrates:
1. **Client** creates and sends a `command'`
2. **CommandTopic** routes the command to the appropriate aggregate
3. **Aggregate** processes the command and produces `event'` instances
4. **EventLog** persists events for durability and replay
5. **EventTopic** publishes events to subscribers
6. **ReadModel** consumes events to update projections

### Message Correlation

Message correlation enables tracing related messages through the system:

```d2
C1: "Command\nmsgId: cmd-001\ncorrelationId: cmd-001" { class: msg-command }
A: Aggregate { class: aggregate }
E1: "Event\nmsgId: evt-001\ncorrelationId: cmd-001" { class: msg-event }
E2: "Event\nmsgId: evt-002\ncorrelationId: cmd-001" { class: msg-event }
EM: EventMapper { class: event-mapper }
RM2: ReadModel { class: read-model }
C2: "Command\nmsgId: cmd-002\ncorrelationId: evt-001" { class: msg-command }

C1 -> A { class: command-flow }
A -> E1 { class: event-flow }
A -> E2 { class: event-flow }
E1 -> EM { class: event-flow }
E2 -> RM2 { class: event-flow }
EM -> C2 { class: command-flow }
```

**Key Principles**:
- Original commands set `correlationId` equal to their `msgId`
- Resulting events maintain the original `correlationId`
- New commands triggered by events use the triggering event's `msgId` as their `correlationId`

### Message Transformation

Messages undergo various transformations as they flow through the system:

```d2
CMD: command' { class: msg-command }
CJSON: commandJson
CMD2: command' { class: msg-command }
EVT: event' { class: msg-event }
EJSON: eventJson
EVT2: event' { class: msg-event }

CMD -> CJSON: serialize
CJSON -> CMD2: deserialize
CMD2 -> EVT: process
EVT -> EJSON: encode
EJSON -> EVT2: decode
```

**Transformation Types**:
- **Serialization**: `command'` to `commandJson` for transport
- **Encoding/Decoding**: Type-safe conversion to/from JSON
- **Schema Evolution**: Handling version changes in message formats

## Practical Examples

### Creating and Sending Commands

```rescript
// Example: Creating a customer creation command
let createCustomerCommand = {
  id: "customer-123",
  meta: Message.generateMeta(~service="CustomerService", ~user="john.doe"),
  command: Customer.Create({
    name: "John Doe", 
    email: "john@example.com",
    address: "123 Main St"
  })
}

// The generateMeta function creates proper metadata
let meta = Message.generateMeta(~service="OrderService", ~user="jane.smith")
// Results in:
// {
//   service: "OrderService",
//   time: "2024-08-13T10:30:00.000Z",
//   ip: "",
//   user: "jane.smith", 
//   msgId: "uuid-generated-id",
//   correlationId: "uuid-generated-id"  // same as msgId for original commands
// }
```

### Processing Events

```rescript
// Example: Event handler processing customer events
let handleCustomerEvent = (event': Message.event'<string, CustomerEvent.t>) => {
  // Log the event for debugging
  Js.log3("Processing event:", event'.meta.msgId, event'.event)
  
  switch event'.event {
  | CustomerCreated(data) => 
    // Update read model with new customer
    CustomerView.create(event'.id, {
      name: data.name,
      email: data.email,
      createdAt: event'.meta.time,
      createdBy: event'.meta.user
    })
    
  | CustomerUpdated(data) =>
    // Handle customer update
    CustomerView.update(event'.id, {
      name: data.name,
      email: data.email,
      updatedAt: event'.meta.time,
      updatedBy: event'.meta.user
    })
    
  | CustomerDeleted(_) =>
    // Handle customer deletion
    CustomerView.delete(event'.id)
  }
}
```

### Message Correlation Example

```rescript
// Original command that starts a workflow
let originalCommand = {
  id: "order-456",
  meta: {
    service: "OrderService",
    time: "2024-08-13T10:30:00.000Z",
    ip: "192.168.1.100",
    user: "customer@example.com",
    msgId: "msg-001",
    correlationId: "msg-001", // Same as msgId for original commands
  },
  command: Order.Create({
    customerId: "customer-123",
    items: [{productId: "prod-1", quantity: 2}],
    totalAmount: 99.98
  })
}

// Resulting event maintains correlation
let resultingEvent = {
  id: "order-456", 
  meta: {
    service: "OrderService",
    time: "2024-08-13T10:30:01.000Z",
    ip: "192.168.1.100", 
    user: "customer@example.com",
    msgId: "msg-002",
    correlationId: "msg-001", // Links back to original command
  },
  event: Order.Created({
    customerId: "customer-123",
    items: [{productId: "prod-1", quantity: 2}],
    totalAmount: 99.98,
    status: "Pending"
  })
}

// Subsequent command triggered by the event
let followupCommand = {
  id: "inventory-prod-1",
  meta: {
    service: "InventoryService", 
    time: "2024-08-13T10:30:02.000Z",
    ip: "192.168.1.101",
    user: "system",
    msgId: "msg-003",
    correlationId: "msg-002", // Links to the triggering event
  },
  command: Inventory.Reserve({
    productId: "prod-1",
    quantity: 2,
    orderId: "order-456"
  })
}
```

## Message Utility Functions

### Message Creation

#### `generateMeta()`
Creates message metadata with proper defaults and unique identifiers.

```rescript
let generateMeta: (~service: string, ~ip: string=?, ~user: string=?) => meta
```

**Usage**:
```rescript
let meta = Message.generateMeta(~service="CustomerService", ~user="john.doe")
// Generates unique msgId and sets correlationId to the same value
```

#### `uuid()`
Generates unique identifiers for messages and entities.

```rescript
let uuid: unit => string
```

#### `nowAsISOString()`
Creates ISO timestamp strings for message timing.

```rescript
let nowAsISOString: unit => string
// Returns: "2024-08-13T10:30:00.000Z"
```

### Message Encoding/Decoding

#### `encode()` / `decode()`
Schema-based serialization for type-safe message handling.

```rescript
let encode: ('a, S.t<'a>) => Js.Json.t
let decode: (Js.Json.t, S.t<'a>) => 'a
```

#### `encodeEvent'()` / `decodeEvent'()`
Specialized encoding/decoding for event messages.

```rescript
let encodeEvent': (event'<'id, 'event>, S.t<'id>, S.t<'event>) => Js.Json.t
let decodeEvent': (Js.Json.t, S.t<'id>, S.t<'event>) => event'<'id, 'event>
```

#### `encodeCommand'()` / `decodeCommand'()`
Specialized encoding/decoding for command messages.

```rescript
let encodeCommand': (command'<'id, 'command>, S.t<'id>, S.t<'command>) => Js.Json.t
let decodeCommand': (Js.Json.t, S.t<'id>, S.t<'command>) => command'<'id, 'command>
```

### Message Analysis

#### `serviceNameOfMsg()`
Extracts the service name from a message JSON.

```rescript
let serviceNameOfMsg: Js.Json.t => option<string>
```

**Usage**:
```rescript
let serviceName = Message.serviceNameOfMsg(messageJson)
// Returns: Some("CustomerService") or None if parsing fails
```

#### `eventNameOfEvent'Json()`
Gets the event type name from an event message JSON.

```rescript
let eventNameOfEvent'Json: Js.Json.t => string
```

#### `variantNameOfJson()`
Extracts variant information from JSON representations.

```rescript
let variantNameOfJson: Js.Json.t => string
```

## Advanced Patterns

### Message Splitting and Combining

#### `splitMessage()`
Decomposes messages into type and payload components.

```rescript
let splitMessage: Js.Json.t => (string, Dict.t<Js.Json.t>)
```

**Usage**:
```rescript
let (messageType, payload) = Message.splitMessage(messageJson)
// Returns: ("CustomerCreated", {name: "John", email: "john@example.com"})
```

#### `combineMessage()`
Reconstructs messages from type and data components.

```rescript
let combineMessage: (string, Dict.t<Js.Json.t>) => Js.Json.t
```

**Use Cases**:
- Message transformation and routing
- Protocol adaptation between services
- Message filtering and enrichment

### Error Handling Patterns

#### Exception Types
```rescript
exception InvalidEvent(Js.Json.t)
exception InvalidCommand(Js.Json.t)
```

#### Error Propagation
When message processing fails, errors should:
1. Preserve the original message for debugging
2. Maintain correlation information
3. Generate appropriate error events
4. Support retry mechanisms

#### Dead Letter Queue Patterns
```rescript
// Example error handling in message processing
let processMessage = (messageJson) => {
  try {
    let command = Message.decodeCommand'(messageJson, idSchema, commandSchema)
    // Process command...
  } catch {
  | Message.InvalidCommand(json) => 
    // Send to dead letter queue with correlation info
    DeadLetterQueue.send(~reason="Invalid command format", ~originalMessage=json)
  | exn => 
    // Log error and potentially retry
    Js.log2("Message processing failed:", exn)
    RetryQueue.schedule(~message=messageJson, ~delay=5000)
  }
}
```

### Message Versioning

#### Schema Evolution Strategies

1. **Additive Changes**: New optional fields can be added safely
2. **Field Renaming**: Use schema transformations to map old to new names  
3. **Breaking Changes**: Require version-specific handlers

#### Backward Compatibility
```rescript
// Example: Handling multiple versions of customer events
let handleCustomerEventV1 = (event) => {
  // Handle old format
  switch event {
  | CustomerCreated({name, email}) => 
    // Convert to new format with default values
    CustomerCreated({name, email, address: None, phone: None})
  }
}

let handleCustomerEventV2 = (event) => {
  // Handle new format directly
  event
}
```

#### Migration Patterns
- Use event upcasting to transform old events to new formats
- Maintain multiple schema versions during transition periods
- Implement gradual rollout strategies for schema changes

## Reference Section

### Type Definitions

#### From `reventless-spec/src/Message.res`

```rescript
type service = string

type meta = {
  service: service,
  time: string,
  ip: string, 
  user: string,
  msgId: string,
  correlationId: string,
}

type context = {
  id: string,
  meta: meta,
}

type event'<'id, 'event> = {
  id: 'id,
  meta: meta,
  event: 'event,
}

type command'<'id, 'command> = {
  id: 'id,
  meta: meta,
  command: 'command,
}

type commandJson = {
  id: string,
  meta: meta,
  commandJson: Js.Json.t,
  delay?: int,
}

type statusChange = {
  at: string,
  by: string,
}
```

#### From `reventless/src/Message.res`

```rescript
module type Service = {
  module Id: Reventless.Id.T
  type id = Id.t
  type command
  type event  
  type error
  let name: string
}

type handler<'msg> = 'msg => Js.Promise.t<unit>
type commandHandler<'id, 'command> = command'<'id, 'command> => Js.Promise.t<unit>
type commandsHandler<'id, 'command> = ('id, array<command'<'id, 'command>>) => Js.Promise.t<unit>
type eventsHandler<'id, 'event> = ('id, array<event'<'id, 'event>>) => Js.Promise.t<unit>
type errorHandler<'error, 'command, 'event> = ('error, 'command, context) => array<'event>

exception InvalidEvent(Js.Json.t)
exception InvalidCommand(Js.Json.t)
```

### Function Reference

#### Message Creation
- `generateMeta(~service, ~ip=?, ~user=?)` - Generate message metadata
- `uuid()` - Generate unique identifier
- `nowAsISOString()` - Current timestamp as ISO string
- `now()` - Current timestamp as float

#### Encoding/Decoding
- `encode(value, schema)` - Encode value to JSON using schema
- `decode(json, schema)` - Decode JSON to value using schema
- `encodeEvent'(event', idSchema, eventSchema)` - Encode event message
- `decodeEvent'(json, idSchema, eventSchema)` - Decode event message
- `encodeCommand'(command', idSchema, commandSchema)` - Encode command message
- `decodeCommand'(json, idSchema, commandSchema)` - Decode command message

#### Message Analysis
- `serviceNameOfMsg(json)` - Extract service name from message
- `eventNameOfEvent'Json(json)` - Get event name from event JSON
- `variantNameOfJson(json)` - Extract variant name from JSON
- `idOfEvent'Json(json)` - Extract ID from event JSON
- `idMetaEventOfEvent'Json(json)` - Extract ID, meta, and event from JSON

#### Message Transformation
- `splitMessage(json)` - Split message into type and payload
- `combineMessage(type, data)` - Combine type and data into message
- `commandJsonOfCommand'(~idToString, ~commandSchema, command')` - Convert command' to commandJson
- `toMessageBody(commandJson)` - Convert commandJson to message body string

#### Utility Functions
- `decomposeMeta(meta)` - Decompose meta into key-value pairs
- `composeMeta(dict)` - Compose meta from dictionary
- `composeEventJson'(id, meta, ~recordedAt, eventJson)` - Compose the `{id, meta, recordedAt, event}` topic envelope
- `log(value, str)` - Log value with message and return value

### Common Patterns

#### Command Creation Pattern
```rescript
let createCommand = (~id, ~service, ~user, ~commandData) => {
  id,
  meta: Message.generateMeta(~service, ~user),
  command: commandData
}
```

#### Event Processing Pattern
```rescript
let processEvents = (events: array<event'<'id, 'event>>) => {
  events->Array.forEach(event' => {
    Js.log2("Processing event:", event'.meta.msgId)
    // Handle event based on type
    handleEvent(event')
  })
}
```

#### Correlation Tracking Pattern
```rescript
let trackCorrelation = (originalMsgId, newMessage) => {
  {
    ...newMessage,
    meta: {
      ...newMessage.meta,
      correlationId: originalMsgId
    }
  }
}
```

#### Error Handling Pattern
```rescript
let safeMessageProcessing = (messageJson, processor) => {
  try {
    processor(messageJson)
  } catch {
  | Message.InvalidEvent(json) => 
    Js.log2("Invalid event:", json)
    Error("Invalid event format")
  | Message.InvalidCommand(json) =>
    Js.log2("Invalid command:", json) 
    Error("Invalid command format")
  | exn =>
    Js.log2("Processing error:", exn)
    Error("Processing failed")
  }
}
```

---

This comprehensive documentation provides both conceptual understanding for newcomers and detailed reference material for experienced developers. The message system forms the backbone of reventless's event-sourcing architecture, enabling reliable, traceable, and scalable distributed systems.
