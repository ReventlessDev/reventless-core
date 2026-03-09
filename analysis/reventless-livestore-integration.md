# Reventless + LiveStore Integration Analysis

## Executive Summary

Reventless (server-side event-sourced CQRS framework) and LiveStore (client-side reactive SQLite with event-sourced sync) share a common foundation in event sourcing, making them natural candidates for integration. This analysis explores how a Reventless backend could serve as the sync backend and authority for LiveStore-based clients, enabling local-first applications with full server-side domain logic enforcement.

## 1. Architecture Overview

### 1.1 Reventless (Server Side)

Reventless is an event-sourced CQRS framework for serverless infrastructure (AWS Lambda, DynamoDB, SQS, SNS). Its key components:

- **Aggregates** process commands and emit events, enforcing business invariants
- **EventLog** provides append-only event storage with replay and optimistic concurrency control
- **EventTopic** fans out events to subscribers (SNS)
- **ReadModels** project events into queryable state (DynamoDB via QueryDb)
- **CommandGenerator** bridges GraphQL mutations to aggregate commands
- **Plugins** group components into bounded contexts / deployment units

The command-to-event flow: `Client -> GraphQL API -> CommandGenerator -> CommandTopic (SQS FIFO) -> Aggregate -> EventLog (DynamoDB) -> EventTopic (SNS) -> ReadModel -> QueryDb`

### 1.2 LiveStore (Client Side)

LiveStore is a client-side state management framework based on reactive SQLite and event sourcing. Its key components:

- **Eventlog** is the append-only log of all events (single source of truth)
- **Materializers** map events to SQL statements that update the local SQLite database
- **Reactive SQLite** provides synchronous, in-memory queries for UI components
- **Sync Engine** implements git-like push/pull with client-side rebasing

The client flow: `User Interaction -> store.commit(event) -> Local Eventlog -> Materializers -> SQLite -> Reactive UI`

The sync flow: `Client pulls upstream events -> Rebases local pending events -> Pushes local events to sync backend`

### 1.3 Shared Foundation

Both systems are built on event sourcing:

| Concept | Reventless | LiveStore |
|---------|-----------|-----------|
| Event storage | EventLog (DynamoDB) | Local eventlog (SQLite/IndexedDB) |
| Event projection | ReadModel projections | Materializers (events -> SQL) |
| Ordering | Per-aggregate sequence numbers | Global sequence numbers |
| Concurrency | Optimistic (sequence number check) | Push/pull with rebasing |
| Serialization | sury (JSON schemas) | Effect Schema (JSON) |

## 2. Integration Models

### 2.1 Model A: Reventless as LiveStore Sync Backend (Recommended)

In this model, the Reventless backend acts as the authoritative sync backend for LiveStore clients. The Reventless EventLog becomes the global source of truth, and LiveStore clients sync their local eventlogs against it.

```
LiveStore Client                    Reventless Backend
+------------------+                +---------------------------+
| Local Eventlog   | <-- pull ----> | Sync API (new component)  |
| Materializers    |                |   |                       |
| Reactive SQLite  |                |   v                       |
| UI Components    | --- push ----> | EventLog (DynamoDB)       |
+------------------+                | Aggregate (validation)    |
                                    | EventTopic (fan-out)      |
                                    | ReadModel (server queries)|
                                    +---------------------------+
```

**How it works:**

1. **Pull**: Client requests events from the Reventless EventLog starting from a cursor (last known sequence number). The sync API queries DynamoDB for events after that cursor and streams them to the client.

2. **Push**: Client sends its local pending events to the Reventless sync API. The server validates each event through the appropriate Aggregate's command handler (enforcing business invariants), appends valid events to the EventLog, and returns the result.

3. **Rebase**: If the server rejects a push because new events exist, the client pulls those events first, rebases its local pending events, and retries.

**Key design decision**: LiveStore events on the client map to Reventless *commands* on the server. The server-side Aggregate validates the command and emits the canonical event. This preserves Reventless's invariant enforcement while giving LiveStore clients optimistic local updates.

### 2.2 Model B: Thin Sync Layer with Separate Command Path

In this model, there are two separate paths: commands go through the existing Reventless GraphQL API, and a separate sync channel pushes server events to clients.

```
LiveStore Client                    Reventless Backend
+------------------+                +---------------------------+
| Local Eventlog   | <-- events --- | Event Stream (new)        |
| Materializers    |                |   ^                       |
| Reactive SQLite  |                |   |                       |
| UI Components    | --- cmds ----> | GraphQL API (existing)    |
+------------------+                | CommandGenerator          |
                                    | Aggregate -> EventLog     |
                                    | EventTopic -> Stream      |
                                    +---------------------------+
```

**How it works:**

1. Client sends commands through the existing GraphQL API (CommandGenerator path)
2. Server processes commands normally through the Aggregate pipeline
3. A new Event Stream component subscribes to EventTopic and pushes events to connected clients (WebSocket/SSE)
4. Client receives events and materializes them into local SQLite

**Trade-off**: Simpler server-side changes (reuses existing command path), but loses LiveStore's offline-first push/pull model. The client can still work offline for reads, but writes require connectivity.

### 2.3 Model C: Hybrid (Command Validation + Event Sync)

Combines the best of both models: LiveStore's push/pull sync for events, with Reventless command validation on push.

```
LiveStore Client                    Reventless Backend
+------------------+                +---------------------------+
| Local Eventlog   | <-- pull ----> | Sync API                  |
| Materializers    |                |   |                       |
| Reactive SQLite  | --- push ----> |   v                       |
| UI Components    |                | Command Validator         |
+------------------+                |   |                       |
                                    |   v                       |
                                    | Aggregate -> EventLog     |
                                    | EventTopic (fan-out)      |
                                    +---------------------------+
```

**How it works:**

1. Client commits events locally (optimistic) and materializes immediately
2. On push, the sync API translates client events into Reventless commands
3. Each command goes through the Aggregate for validation
4. If validation succeeds, the Aggregate emits the canonical server event
5. The canonical event may differ from the client's optimistic event (e.g., server adds timestamps, computed fields)
6. On the next pull, the client receives the canonical events and rebases

This is the **recommended approach** because it preserves:
- LiveStore's offline-first, optimistic UI updates
- Reventless's business invariant enforcement
- The event-sourced sync protocol both systems share

## 3. Technical Integration Design

### 3.1 Event Mapping: Client Events <-> Server Commands/Events

The critical design challenge is mapping between LiveStore's client-side events and Reventless's command/event model.

#### Client-Side Event Definition (LiveStore)

```typescript
// events.ts (LiveStore client)
import { Events, Schema } from '@livestore/livestore'

export const events = {
  // Synced events (map to Reventless commands)
  todoCreated: Events.synced({
    name: 'v1.TodoCreated',
    schema: Schema.Struct({
      id: Schema.String,
      text: Schema.String,
    }),
  }),
  todoCompleted: Events.synced({
    name: 'v1.TodoCompleted',
    schema: Schema.Struct({
      id: Schema.String,
    }),
  }),

  // Client-only events (never synced to server)
  filterChanged: Events.clientOnly({
    name: 'v1.FilterChanged',
    schema: Schema.Struct({
      filter: Schema.String,
    }),
  }),
}
```

#### Server-Side Aggregate Spec (Reventless)

```rescript
// Todo.res (Reventless server)
module Id = Reventless.Id.String
let name = "Todo"

@schema
type command =
  | CreateTodo({id: string, text: string})
  | CompleteTodo({id: string})

@schema
type event =
  | TodoCreated({id: string, text: string})
  | TodoCompleted({id: string})

@schema
type error =
  | TodoAlreadyExists
  | TodoNotFound
  | TodoAlreadyCompleted
```

#### Mapping Layer (Sync API)

The sync API component translates between the two:

```
Client Event             ->  Server Command         ->  Server Event
v1.TodoCreated{id,text}  ->  CreateTodo{id,text}    ->  TodoCreated{id,text}
v1.TodoCompleted{id}     ->  CompleteTodo{id}       ->  TodoCompleted{id}
```

The mapping is configured per-aggregate and could be auto-generated from shared schema definitions.

### 3.2 Sync API Component

A new Reventless component (`SyncApi`) that acts as the LiveStore sync backend.

**Required operations:**

| Operation | Description | LiveStore Protocol |
|-----------|-------------|-------------------|
| `pull(cursor)` | Return events after cursor | GET /sync/pull?cursor=N |
| `push(events)` | Validate and append events | POST /sync/push |
| `subscribe()` | Real-time event notifications | WebSocket / SSE |

**Pull implementation:**

```
1. Receive cursor (last known global sequence number)
2. Query EventLog(s) for events with sequence > cursor
3. Transform Reventless events to LiveStore event format
4. Return ordered event list + new cursor
```

**Push implementation:**

```
1. Receive batch of client events + client's current cursor
2. Check if cursor matches server head (no new events since client last pulled)
   - If not: return "pull required" with new events
3. For each client event:
   a. Map to Reventless command
   b. Route to appropriate Aggregate
   c. Aggregate validates command and emits events
   d. Append events to EventLog
4. Return success + new cursor
5. Important: serialize push requests to maintain total ordering
```

### 3.3 Sequence Number Mapping

Reventless uses per-aggregate sequence numbers for optimistic concurrency. LiveStore uses a global sequence number across all events. The sync API needs to bridge this gap.

**Option A: Global Sequence Counter**
Add a global sequence counter (DynamoDB atomic counter or separate table) that assigns monotonically increasing IDs to all events across all aggregates. This is the natural fit for LiveStore's model.

**Option B: Composite Cursor**
Use a composite cursor encoding per-aggregate sequence numbers: `{aggregate1: 5, aggregate2: 12, ...}`. More complex but avoids a global bottleneck.

**Recommendation**: Option A (global sequence counter) is simpler and aligns with LiveStore's expectation of a single ordered event stream. The DcbEventLog already provides a shared event log with global ordering, making it the better fit for LiveStore integration.

### 3.4 Event Scoping

LiveStore syncs all events for a "store" (typically per-user or per-workspace). Reventless aggregates can have many instances. The sync API needs to scope which events a client receives.

**Scoping strategies:**

1. **Per-user store**: Client receives all events for aggregates the user has access to
2. **Per-workspace store**: Client receives all events within a bounded context (Plugin)
3. **Per-aggregate store**: One LiveStore instance per aggregate instance (simplest but most limited)
4. **Subscription-based**: Client declares which aggregate types/instances it wants to subscribe to

The scoping strategy should align with the Plugin boundary in Reventless, since Plugins represent bounded contexts.

### 3.5 DCB-Based Plugins as Natural Fit

Reventless's DCB (Dynamic Consistency Boundary) model is a particularly good fit for LiveStore integration because:

1. **Shared event log**: DCB plugins already use a shared `DcbEventLog` across all StateChangeSlices, which naturally maps to LiveStore's single eventlog
2. **Tag-based queries**: DCB events support tag-based queries, which could be used for client-side event filtering
3. **StateViewSlice**: Already combines event collection and projection (similar to LiveStore's materializers)
4. **Global ordering**: DcbEventLog inherently provides global event ordering

The mapping becomes:

```
LiveStore Concept        <->  DCB Concept
Eventlog                 <->  DcbEventLog
Materializer             <->  StateViewSlice
store.commit(event)      <->  StateChangeSlice.handle(command)
SQLite table             <->  QueryDb table
```

## 4. Implementation Considerations

### 4.1 New Components Required

1. **SyncApi** - New Reventless component implementing the LiveStore sync backend protocol
   - Handles pull/push/subscribe operations
   - Maps between client events and server commands
   - Manages global sequence numbering
   - Enforces access control / scoping

2. **EventStream** - Real-time event delivery to connected clients
   - WebSocket or SSE endpoint
   - Subscribes to EventTopic for new events
   - Filters events per client scope
   - Could be implemented as an AWS API Gateway WebSocket + Lambda

3. **SyncAdapter** - Infrastructure adapter for the sync protocol
   - AWS: API Gateway (HTTP + WebSocket) + Lambda + DynamoDB (cursor/session state)
   - In-Memory: Direct function calls (for testing)

### 4.2 Schema Synchronization

Both systems need compatible schemas. Options:

1. **Shared schema definition** (ideal): Define events once in a shared format, generate both LiveStore `events.ts` and Reventless `Spec` from it
2. **Code generation**: Generate LiveStore event definitions from Reventless Spec (or vice versa) during build
3. **Runtime validation**: Validate at the sync API boundary using both schemas

Since Reventless uses sury (`@schema` PPX) and LiveStore uses Effect Schema, a code generation approach that produces both formats from a single source would be most maintainable.

### 4.3 Conflict Resolution

LiveStore defaults to last-write-wins but supports custom conflict resolution. Reventless uses optimistic concurrency with retry at the Aggregate level.

**Integrated conflict resolution flow:**

1. Client commits event optimistically (instant local feedback)
2. Client pushes event to sync API
3. Sync API maps to command and sends to Aggregate
4. If Aggregate rejects (e.g., `TodoAlreadyCompleted`):
   - Sync API returns rejection to client
   - Client receives the rejection and can either:
     a. Drop the local event (undo optimistic update)
     b. Transform the event and retry (client-side rebase logic)
5. If concurrent modification (sequence number conflict):
   - Follow standard LiveStore rebase flow
   - Re-validate rebased events through Aggregates

### 4.4 Offline Support

LiveStore's offline-first architecture pairs well with Reventless:

- **Offline reads**: Client reads from local SQLite (always available)
- **Offline writes**: Client commits events locally, queues for push
- **Reconnection**: Client pulls missed events, rebases local pending events, pushes
- **Server validation on reconnect**: Queued events are validated through Aggregates when connectivity returns. Some may be rejected if state has changed.

### 4.5 Security Considerations

- **Command authorization**: The sync API must verify the client has permission to execute each command. Reventless's `Message.meta.user` field carries the authenticated user.
- **Event filtering**: Clients should only receive events they are authorized to see. The sync API must filter events based on user permissions before sending.
- **Input validation**: All client events must be validated through Aggregates before being accepted. Never bypass the Aggregate for writes.

## 5. Advantages of Integration

1. **Local-first UX**: Instant UI responses with optimistic updates, offline support
2. **Server-side authority**: Business invariants enforced by Reventless Aggregates
3. **Reactive queries**: LiveStore's reactive SQLite eliminates loading states
4. **Event sourcing end-to-end**: Same paradigm from client to server, simplifying mental model
5. **Existing infrastructure**: Reventless's serverless infrastructure (Lambda, DynamoDB, SQS) handles scaling
6. **Multi-client sync**: LiveStore's sync engine handles multi-device/multi-user synchronization

## 6. Challenges and Risks

1. **Schema evolution**: Both systems need coordinated schema changes. Breaking changes in events require migration on both client and server.
2. **Event translation overhead**: Mapping between client events and server commands adds complexity and a potential source of bugs.
3. **Global ordering bottleneck**: A global sequence counter can become a throughput bottleneck under high write load. DynamoDB atomic counters support ~1000 writes/second.
4. **Unbounded data**: LiveStore doesn't scale for unbounded data. If an aggregate accumulates thousands of events, the client eventlog grows large. Snapshots/compaction would be needed.
5. **Aggregate boundary mismatch**: LiveStore assumes a single eventlog per store; Reventless uses per-aggregate or per-DCB event logs. The sync API must merge/split event streams.
6. **Latency**: LiveStore expects fast push/pull round-trips. Lambda cold starts could add latency. Consider provisioned concurrency or edge deployment.

## 7. Recommended Next Steps

1. **Proof of concept**: Build a minimal SyncApi component using the in-memory platform, demonstrating push/pull with a simple aggregate (e.g., Todo list)
2. **Schema tooling**: Prototype shared schema definitions that generate both LiveStore and Reventless types
3. **DCB-first approach**: Start with DCB-based plugins since their shared event log maps most naturally to LiveStore
4. **AWS adapter**: Implement the SyncApi AWS adapter (API Gateway WebSocket + Lambda)
5. **Client library**: Build a LiveStore sync provider package (`@livestore/sync-reventless`) that implements the custom sync provider interface

## 8. Conclusion

Reventless and LiveStore are architecturally complementary. Both are built on event sourcing, but they operate at different layers: Reventless handles server-side domain logic, infrastructure, and persistence; LiveStore handles client-side state management, reactivity, and offline support. The integration point is the sync protocol, where LiveStore's push/pull mechanism maps naturally to Reventless's EventLog and Aggregate pipeline.

The DCB-based plugin model in Reventless is the most natural fit for LiveStore integration due to its shared event log and global ordering. The recommended approach (Model C: Hybrid) preserves both LiveStore's offline-first optimistic updates and Reventless's business invariant enforcement, providing a best-of-both-worlds architecture for local-first applications with server-side authority.
