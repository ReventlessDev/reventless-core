---
title: AutomationSlice
date: 2026-03-03
draft: false
---

For a short summary of AutomationSlice, see [Reventless Components Overview.](../component-overview.md#automationslice)

:::info Framework Implementation
This component follows the Reventless [Component Structure Pattern](/framework/inner-workings/component-structure-pattern), using separate files for interface definitions ([`AutomationSlice.res`](../../reventless/reventless-core/src/components/AutomationSlice/AutomationSlice.res)), builder logic ([`AutomationSlice_Builder.res`](../../reventless/reventless-core/src/components/AutomationSlice/AutomationSlice_Builder.res)), and callback/handler logic ([`AutomationSlice_Callback.res`](../../reventless/reventless-core/src/components/AutomationSlice/AutomationSlice_Callback.res)).
:::

## Overview

```d2
DcbEventLog: DcbEventLog { class: dcb-event-log }
EventTopic: Event Topic { class: event-topic }
AutomationSlice: AutomationSlice { class: automation-slice }
TodoQueryDb: TODO List QueryDb { class: query-db }
CommandTopic: Command Topic { class: command-topic }
StateChangeSlice: StateChangeSlice { class: state-change-slice }

DcbEventLog -> EventTopic: publish { class: event-flow }
EventTopic -> AutomationSlice: events { class: event-flow }
AutomationSlice -> TodoQueryDb: sync TODO state { class: projection-flow }
AutomationSlice -> CommandTopic: commands { class: command-flow }
CommandTopic -> StateChangeSlice: commands { class: command-flow }
StateChangeSlice -> DcbEventLog: append { class: event-flow }
```

The **AutomationSlice** implements the Event Modeling **Automation** pattern (TODO List Pattern) as a first-class DCB component. It listens to events from a shared DcbEventLog, accumulates pending work items into a TODO list, processes them exactly once by issuing commands, and marks items as completed when resolution events arrive.

## Event Modeling: The Automation Pattern

In Event Modeling, an **Automation** (also called a **Processor** or **Policy**) is the pattern that bridges read-side projections with write-side commands:

```
Event(s) --> TODO List (read model) --> Processor --> Command --> Event(s)
```

The key insight is that the automation maintains a **stateful TODO list** of pending work, rather than mapping events directly to commands. This provides:

- **Idempotency** -- replaying events does not duplicate commands because already-known items are skipped
- **Visibility** -- the TODO list is a queryable read model showing pending vs completed work
- **Retry semantics** -- failed items can be retried individually without reprocessing everything
- **Completion tracking** -- items are only marked done when a corresponding completion event arrives

## Purpose and Responsibilities

- **Responsibility**: Collect pending work items from events; process each item exactly once by issuing commands; track completion via resolution events; provide retry and heartbeat semantics
- **In**: Events from DcbEventLog (subscribed via EventCollector)
- **Out**: Commands to CommandTopic (via `publishJsons`); TODO state synced to QueryDb
- **Key Feature**: Stateful processing with exactly-once semantics, unlike the stateless EventMapper

## Component Spec

The AutomationSlice spec defines three core functions -- **collect**, **resolve**, and **process** -- that together implement the TODO list lifecycle:

```rescript
module type Spec = {
  let name: string
  module DcbEventLogSpec: DcbEventLog.Spec

  @schema type todoItem
  @schema type command

  let collect: DcbEventLogSpec.event => array<(string, todoItem)>
  let resolve: DcbEventLogSpec.event => option<string>
  let process: (string, todoItem) => option<(string, command)>

  let maxRetries: int
  let heartbeatInterval: int
}
```

### Spec Fields Explained

| Field | Type | Description |
|-------|------|-------------|
| `name` | `string` | Unique identifier for this automation slice |
| `DcbEventLogSpec` | `module(DcbEventLog.Spec)` | Reference to the shared event log spec |
| `todoItem` | `@schema type` | Data accumulated for each pending work item |
| `command` | `@schema type` | Command type produced by the processor |
| `collect` | `event => array<(string, todoItem)>` | Map an event to zero or more TODO items (id + payload) |
| `resolve` | `event => option<string>` | Check if an event completes a TODO item (returns item id) |
| `process` | `(string, todoItem) => option<(string, command)>` | Produce a command for a pending item (target id + command) |
| `maxRetries` | `int` | Maximum retry attempts for failed items |
| `heartbeatInterval` | `int` | Seconds between heartbeat sweeps for pending/failed items |

### The Three Functions

**`collect`** -- When an event arrives, `collect` decides whether it creates new TODO items. Each item has a string `id` (used as a deduplication key) and a `todoItem` payload. Returns an empty array for irrelevant events. If an item with the same id already exists, it is skipped (idempotent).

**`resolve`** -- When an event arrives, `resolve` checks if it marks an existing TODO item as completed. Returns `Some(itemId)` to mark that item done, or `None` to skip. This closes the automation loop -- the command produced by `process` eventually causes events that `resolve` recognizes.

**`process`** -- For each pending item, `process` decides what command to issue. Returns `Some((targetId, command))` to publish a command, or `None` to skip processing (e.g., waiting for more data). Skipped items remain pending for the next heartbeat sweep.

## Usage Pattern

### Complete Example: Ship Order Automation

This example automates order shipping. When an `OrderPlaced` event arrives, a TODO item is created. The processor issues a `CreateShipment` command. When the `ShipmentCreated` event arrives, the TODO item is resolved.

```rescript title="ShipOrder.res"
// Shared DCB event log spec
module DcbEventLogSpec = OrderingEventLog

let name = "ShipOrder"

@schema
type todoItem = {orderId: string, shippingAddress: string}

@schema
type command = CreateShipment({
  orderId: @s.matches(DcbTag.string) string,
  address: string,
})

let collect = event =>
  switch event {
  | OrderingEventLog.OrderPlaced({orderId, shippingAddress}) =>
    [(orderId, {orderId, shippingAddress})]
  | _ => []
  }

let resolve = event =>
  switch event {
  | OrderingEventLog.ShipmentCreated({orderId}) => Some(orderId)
  | _ => None
  }

let process = (id, item) =>
  Some((id, CreateShipment({orderId: item.orderId, address: item.shippingAddress})))

let maxRetries = 3
let heartbeatInterval = 60
```

### Registering in a DcbSpec

AutomationSlices are registered alongside StateChangeSlices and StateViewSlices in the Plugin's DcbSpec:

```rescript title="OrderingPlugin.res"
module DcbSpec = {
  @schema type event = OrderingEventLog.event

  let stateChangeSlices = [
    module(CreateOrderSlice),
    module(FulfillOrderSlice),
  ]

  let stateViewSlices = [
    module(OrderViewSlice),
  ]

  let automationSlices = [
    module(ShipOrderSlice),
  ]
}
```

### Creating with Platform

```rescript title="ShipOrderSlice.res"
module ShipOrderSlice = Platform.AutomationSlice.Make(ShipOrder)
```

The framework automatically wires the slice to the shared DcbEventLog and CommandTopic.

## Runtime Behavior

### Two-Phase Processing

The AutomationSlice callback has two phases that execute on each event batch:

```d2
shape: sequence_diagram

DcbEventLog: DcbEventLog { class: dcb-event-log }
EventCollector: EventCollector { class: event-collector }
AutomationSlice: AutomationSlice { class: automation-slice }
TodoList: TODO List
CommandTopic: Command Topic { class: command-topic }
QueryDb: QueryDb { class: query-db }

DcbEventLog -> EventCollector: new events published
EventCollector -> AutomationSlice: "handleEvents(events)"
AutomationSlice -> AutomationSlice: Phase 1: collect + resolve
AutomationSlice -> TodoList: insert Pending items
AutomationSlice -> TodoList: mark Completed items
AutomationSlice -> AutomationSlice: Phase 2: process pending
AutomationSlice -> TodoList: mark items Processing
AutomationSlice -> CommandTopic: "publishJsons(commands)"
AutomationSlice -> QueryDb: sync TODO state
```

**Phase 1 -- Update TODO List** (runs for each event in the batch):

```
for each event:
  for each (id, item) in collect(event):
    if not exists in TODO list:
      insert {id, item, status: Pending}
  match resolve(event):
    Some(id) -> mark item as Completed
    None -> skip
```

**Phase 2 -- Process Pending Items** (runs after Phase 1):

```
for each item where status = Pending
  OR (status = Failed AND retryCount < maxRetries):
    mark status = Processing
    match process(id, item):
      Some(targetId, command) -> publish to CommandTopic
      None -> revert status to Pending (skip)
```

### TODO Item Lifecycle

```d2
direction: right

pending: Pending { class: state-view-slice }
processing: Processing { class: command }
completed: Completed { class: read-model }
failed: Failed { class: side-effect }

pending -> processing: "process() returns Some" { class: command-flow }
processing -> completed: "resolve() matches" { class: projection-flow }
processing -> failed: publish error { class: event-flow }
failed -> processing: "retry (count < max)" { class: command-flow }
pending -> completed: "resolve() before process" { class: projection-flow }
```

Each TODO item moves through these statuses:

| Status | Description |
|--------|-------------|
| `Pending` | Created by `collect`, waiting to be processed |
| `Processing` | `process` returned a command, waiting for resolution event |
| `Completed` | `resolve` matched -- work is done |
| `Failed` | Command publishing failed -- eligible for retry |

### Heartbeat Handler

A periodic heartbeat (configurable via `heartbeatInterval`) runs **Phase 2 only**, catching:

- Items collected in a previous batch where `process` returned `None` (waiting for more data)
- Failed items eligible for retry (`retryCount < maxRetries`)
- Items stuck in `Processing` beyond a timeout

## TODO List Storage

The TODO list is stored in a QueryDb for observability. Each row:

```rescript
type todoStatus = Pending | Processing | Completed | Failed

type todoRow = {
  item: JSON.t,
  status: todoStatus,
  createdAt: string,
  processedAt?: string,
  completedAt?: string,
  retryCount: int,
}
```

This QueryDb is automatically created by the builder and can be queried via the GraphQL API to inspect pending work.

## Comparison with EventMapper

AutomationSlice and EventMapper both react to events and produce commands, but they solve different problems:

| Aspect | EventMapper | AutomationSlice |
|--------|-------------|-----------------|
| **Pattern** | Stateless event-to-command mapping | Stateful TODO list with exactly-once processing |
| **Architecture** | Aggregate-based plugins | DCB-based plugins |
| **Idempotency** | No -- replays cause duplicate commands | Yes -- deduplication by item id |
| **Completion Tracking** | None -- fire and forget | Yes -- resolution events mark items done |
| **Retry** | Relies on EventCollector retry | Built-in per-item retry with configurable max |
| **Visibility** | No queryable state | TODO list queryable via QueryDb |
| **Heartbeat** | None | Periodic sweep for stuck/failed items |
| **Use When** | Simple, direct event-to-command reactions | Complex workflows needing tracking and reliability |

**Choose EventMapper** when you need a simple, direct transformation from events to commands (e.g., "when customer created, create welcome order").

**Choose AutomationSlice** when you need reliable, trackable processing with completion semantics (e.g., "when order placed, create shipment and track until shipped").

## Error Handling

**Phase 1 Errors (collect/resolve):**
- Event decoding failures are logged and skipped
- `collect` and `resolve` are pure functions -- exceptions are unexpected but caught

**Phase 2 Errors (process):**
- `todoItem` decoding failures are logged, item skipped
- Command encoding failures mark item as `Failed` with incremented `retryCount`
- Publishing failures mark all `Processing` items as `Failed` for retry

**Recovery:**
- Failed items are retried up to `maxRetries` times
- Heartbeat sweeps pick up items that need retry
- All errors logged with slice name and context

## Pulumi Outputs

```rescript
type outputs = {
  resources: array<Adapter.resource>,
  queryDb: QueryDb.outputs,
}

type operations = {
  enqueueEvent: EventCollector.enqueueEvent,
  processPending: unit => promise<unit>,
}
```

**Resource Naming:**
- Component type: `reventless:AutomationSlice`
- TODO list QueryDb: `{name}Todo`
- EventCollector: subscribed to DcbEventLog's EventTopic

**Dependencies:**
- DcbEventLog (shared event storage)
- CommandTopic (via `publishJsons` for command publishing)
- QueryDb (for TODO list persistence)

## Related Components

- **[DcbEventLog](./dcbeventlog.md)** -- Shared event log that AutomationSlice subscribes to
- **[StateChangeSlice](./statechangeslice.md)** -- Processes the commands AutomationSlice produces
- **[StateViewSlice](./stateviewslice.md)** -- Another DCB slice type for read-side projections
- **[CommandTopic](./commandtopic.md)** -- Receives commands from the processor
- **[EventCollector](./eventcollector.md)** -- Subscribes to DcbEventLog events
- **[QueryDb](./querydb.md)** -- Stores the TODO list for observability
- **[EventMapper](./eventmapper.md)** -- Stateless alternative for plugins using Aggregates
- **[Plugin](./plugin.md)** -- Hosts AutomationSlice via DcbSpec
