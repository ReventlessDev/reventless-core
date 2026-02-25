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

1. **Client** sends a [`command'`](packages/reventless-spec/src/Message.res:34) to express intent
2. **Aggregate** processes the command and produces [`event'`](packages/reventless-spec/src/Message.res:20) instances
3. **EventLog** persists the events for durability
4. **EventTopic** publishes events to interested subscribers
5. **ReadModels** consume events to update their projections

### Message Types Overview

Reventless defines several core message types:

- **[`meta`](packages/reventless-spec/src/Message.res:5)**: Metadata for tracing and correlation
- **[`context`](packages/reventless-spec/src/Message.res:15)**: Command processing context
- **[`event'<'id, 'event>`](packages/reventless-spec/src/Message.res:20)**: Structured event with metadata
- **[`command'<'id, 'command>`](packages/reventless-spec/src/Message.res:34)**: Structured command with metadata
- **[`commandJson`](packages/reventless-spec/src/Message.res:41)**: Serialized command for transport

## Core Message Types

### Meta Type (`meta`)

The [`meta`](packages/reventless-spec/src/Message.res:5) type provides essential metadata for every message in the system.

```rescript
type meta = {
  service: service,      // service name that created event or is addressed by command
  time: string,          // when message was created (ISO string)
  ip: string,            // IP of service that created message
  user: string,          // user name that initiated message (if any)
  msgId: string,         // unique message id
  correlationId: string, // id of message that caused this message
}
```

**Purpose**: 
- **Distributed Tracing**: Track messages across service boundaries
- **Audit Trails**: Maintain complete history of who did what when
- **Debugging**: Correlate related messages in complex flows

**Usage Patterns**:
- Every message carries meta information
- [`correlationId`](packages/reventless-spec/src/Message.res:11) links causally related messages
- [`msgId`](packages/reventless-spec/src/Message.res:10) provides unique identification for each message

### Context Type (`context`)

The [`context`](packages/reventless-spec/src/Message.res:15) type provides processing context to command handlers.

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

The [`event'`](packages/reventless-spec/src/Message.res:20) type represents structured events with full metadata.

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

The [`command'`](packages/reventless-spec/src/Message.res:34) type represents structured commands with metadata.

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

The [`commandJson`](packages/reventless-spec/src/Message.res:41) type represents serialized commands for transport.

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
ET -> RM: event' { class: projection-flow }
```

This flow demonstrates:
1. **Client** creates and sends a [`command'`](packages/reventless-spec/src/Message.res:34)
2. **CommandTopic** routes the command to the appropriate aggregate
3. **Aggregate** processes the command and produces [`event'`](packages/reventless-spec/src/Message.res:20) instances
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
E2 -> RM2 { class: projection-flow }
EM -> C2 { class: command-flow }
```

**Key Principles**:
- Original commands set [`correlationId`](packages/reventless-spec/src/Message.res:11) equal to their [`msgId`](packages/reventless-spec/src/Message.res:10)
- Resulting events maintain the original [`correlationId`](packages/reventless-spec/src/Message.res:11)
- New commands triggered by events use the triggering event's [`msgId`](packages/reventless-spec/src/Message.res:10) as their [`correlationId`](packages/reventless-spec/src/Message.res:11)

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
- **Serialization**: [`command'`](packages/reventless-spec/src/Message.res:34) to [`commandJson`](packages/reventless-spec/src/Message.res:41) for transport
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

#### [`generateMeta()`](packages/reventless/src/Message.res:173)
Creates message metadata with proper defaults and unique identifiers.

```rescript
let generateMeta: (~service: string, ~ip: string=?, ~user: string=?) => meta
```

**Usage**:
```rescript
let meta = Message.generateMeta(~service="CustomerService", ~user="john.doe")
// Generates unique msgId and sets correlationId to the same value
```

#### [`uuid()`](packages/reventless/src/Message.res:45)
Generates unique identifiers for messages and entities.

```rescript
let uuid: unit => string
```

#### [`nowAsISOString()`](packages/reventless/src/Message.res:54)
Creates ISO timestamp strings for message timing.

```rescript
let nowAsISOString: unit => string
// Returns: "2024-08-13T10:30:00.000Z"
```

### Message Encoding/Decoding

#### [`encode()`](packages/reventless/src/Message.res:20) / [`decode()`](packages/reventless/src/Message.res:19)
Schema-based serialization for type-safe message handling.

```rescript
let encode: ('a, S.t<'a>) => Js.Json.t
let decode: (Js.Json.t, S.t<'a>) => 'a
```

#### [`encodeEvent'()`](packages/reventless/src/Message.res:40) / [`decodeEvent'()`](packages/reventless/src/Message.res:35)
Specialized encoding/decoding for event messages.

```rescript
let encodeEvent': (event'<'id, 'event>, S.t<'id>, S.t<'event>) => Js.Json.t
let decodeEvent': (Js.Json.t, S.t<'id>, S.t<'event>) => event'<'id, 'event>
```

#### [`encodeCommand'()`](packages/reventless/src/Message.res:42) / [`decodeCommand'()`](packages/reventless/src/Message.res:37)
Specialized encoding/decoding for command messages.

```rescript
let encodeCommand': (command'<'id, 'command>, S.t<'id>, S.t<'command>) => Js.Json.t
let decodeCommand': (Js.Json.t, S.t<'id>, S.t<'command>) => command'<'id, 'command>
```

### Message Analysis

#### [`serviceNameOfMsg()`](packages/reventless/src/Message.res:74)
Extracts the service name from a message JSON.

```rescript
let serviceNameOfMsg: Js.Json.t => option<string>
```

**Usage**:
```rescript
let serviceName = Message.serviceNameOfMsg(messageJson)
// Returns: Some("CustomerService") or None if parsing fails
```

#### [`eventNameOfEvent'Json()`](packages/reventless/src/Message.res:106)
Gets the event type name from an event message JSON.

```rescript
let eventNameOfEvent'Json: Js.Json.t => string
```

#### [`variantNameOfJson()`](packages/reventless/src/Message.res:92)
Extracts variant information from JSON representations.

```rescript
let variantNameOfJson: Js.Json.t => string
```

## Advanced Patterns

### Message Splitting and Combining

#### [`splitMessage()`](packages/reventless/src/Message.res:228)
Decomposes messages into type and payload components.

```rescript
let splitMessage: Js.Json.t => (string, Dict.t<Js.Json.t>)
```

**Usage**:
```rescript
let (messageType, payload) = Message.splitMessage(messageJson)
// Returns: ("CustomerCreated", {name: "John", email: "john@example.com"})
```

#### [`combineMessage()`](packages/reventless/src/Message.res:240)
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

#### From [`reventless-spec/src/Message.res`](packages/reventless-spec/src/Message.res)

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

#### From [`reventless/src/Message.res`](packages/reventless/src/Message.res)

```rescript
module type Service = {
  module Id: ReventlessSpec.Id.T
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
- [`generateMeta(~service, ~ip=?, ~user=?)`](packages/reventless/src/Message.res:173) - Generate message metadata
- [`uuid()`](packages/reventless/src/Message.res:45) - Generate unique identifier
- [`nowAsISOString()`](packages/reventless/src/Message.res:54) - Current timestamp as ISO string
- [`now()`](packages/reventless/src/Message.res:52) - Current timestamp as float

#### Encoding/Decoding
- [`encode(value, schema)`](packages/reventless/src/Message.res:20) - Encode value to JSON using schema
- [`decode(json, schema)`](packages/reventless/src/Message.res:19) - Decode JSON to value using schema
- [`encodeEvent'(event', idSchema, eventSchema)`](packages/reventless/src/Message.res:40) - Encode event message
- [`decodeEvent'(json, idSchema, eventSchema)`](packages/reventless/src/Message.res:35) - Decode event message
- [`encodeCommand'(command', idSchema, commandSchema)`](packages/reventless/src/Message.res:42) - Encode command message
- [`decodeCommand'(json, idSchema, commandSchema)`](packages/reventless/src/Message.res:37) - Decode command message

#### Message Analysis
- [`serviceNameOfMsg(json)`](packages/reventless/src/Message.res:74) - Extract service name from message
- [`eventNameOfEvent'Json(json)`](packages/reventless/src/Message.res:106) - Get event name from event JSON
- [`variantNameOfJson(json)`](packages/reventless/src/Message.res:92) - Extract variant name from JSON
- [`idOfEvent'Json(json)`](packages/reventless/src/Message.res:113) - Extract ID from event JSON
- [`idMetaEventOfEvent'Json(json)`](packages/reventless/src/Message.res:119) - Extract ID, meta, and event from JSON

#### Message Transformation
- [`splitMessage(json)`](packages/reventless/src/Message.res:228) - Split message into type and payload
- [`combineMessage(type, data)`](packages/reventless/src/Message.res:240) - Combine type and data into message
- [`commandJsonOfCommand'(~idToString, ~commandSchema, command')`](packages/reventless/src/Message.res:216) - Convert command' to commandJson
- [`toMessageBody(commandJson)`](packages/reventless/src/Message.res:58) - Convert commandJson to message body string

#### Utility Functions
- [`decomposeMeta(meta)`](packages/reventless/src/Message.res:178) - Decompose meta into key-value pairs
- [`composeMeta(dict)`](packages/reventless/src/Message.res:201) - Compose meta from dictionary
- [`composeEventJson'(id, meta, eventJson)`](packages/reventless/src/Message.res:185) - Compose event JSON
- [`log(value, str)`](packages/reventless/src/Message.res:47) - Log value with message and return value

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
