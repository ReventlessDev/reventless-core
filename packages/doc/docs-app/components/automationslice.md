---
title: AutomationSlice
---

For a short summary of AutomationSlice, see [Reventless Components Overview.](../component-overview.md)

:::info Framework Implementation
This component follows the Reventless [Component Structure Pattern](/framework/internals/component-structure-pattern), using separate files for interface definitions (`AutomationSlice.res`), builder logic (`AutomationSlice_Builder.res`), and callback/handler logic (`AutomationSlice_Callback.res`).
:::

:::tip Mixed-source automation
An AutomationSlice can consume events from **multiple sources** — Aggregate `EventTopic`s and DCB `EventLog`s — via per-source `Mapping` modules. `collect` and `resolve` move to the mapping; `process` stays source-agnostic. See the [mixed-source guide](../mixed-source-automationslice.md) for the per-source mapping convention, ambient context, and `toTags` validation.
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

An AutomationSlice is **split into two files**:

- `<Name>.res` — the **spec** (`@@reventless.spec`): the `todoItem` and `command`
  `@schema` types, the sweep config (`maxRetries`, `heartbeatInterval`), and
  `targetName` (the aggregate or StateChangeSlice that receives the produced
  command).
- `<Name>_Automation.res` — the **automation** (`@@reventless.automation`): one or
  more per-source `Mapping.Make` modules (each carrying `collect` + `resolve` for
  that source), the `let mappings` array, and the source-agnostic `let process`.

The spec module type the framework expects:

```rescript
module type Spec = {
  // name and moduleUrl are injected by @@reventless.spec — you never write them

  @schema type todoItem
  @schema type command

  let maxRetries: int
  let heartbeatInterval: int
  let targetName: string
}
```

`collect` and `resolve` live on the per-source `Mapping`. The framework derives
the consumed-event set from each mapping's
`sourceEventSchema`, so there is no manually-declared `consumedEvent` union and
no `DcbEventLogSpec` reference.

### Spec Fields Explained

In the spec file (`@@reventless.spec` injects `name` and `moduleUrl` from the
filename — you don't write them):

| Field | Type | Description |
|-------|------|-------------|
| `todoItem` | `@schema type` | Data accumulated for each pending work item |
| `command` | `@schema type` | Command type produced by the processor |
| `maxRetries` | `int` | Maximum retry attempts for failed items |
| `heartbeatInterval` | `int` | Seconds between heartbeat sweeps for pending/failed items |
| `targetName` | `string` | Name of the aggregate or StateChangeSlice that receives the produced command |

### The Three Functions

`collect` and `resolve` live on each per-source `Mapping` in the
`_Automation.res` file; `process` is source-agnostic and lives at the top level
of that same file.

**`collect`** -- `(sourceEvent, ctx) => array<(string, todoItem)>`. When an event arrives, `collect` decides whether it creates new TODO items. Each item has a string `id` (used as a deduplication key) and a `todoItem` payload. Returns an empty array for irrelevant events. If an item with the same id already exists, it is skipped (idempotent).

**`resolve`** -- `sourceEvent => option<string>`. When an event arrives, `resolve` checks if it marks an existing TODO item as completed. Returns `Some(itemId)` to mark that item done, or `None` to skip. This closes the automation loop -- the command produced by `process` eventually causes events that `resolve` recognizes.

**`process`** -- `(string, todoItem) => option<(string, command)>`. For each pending item, `process` decides what command to issue. Returns `Some((targetId, command))` to publish a command, or `None` to skip processing (e.g., waiting for more data). Skipped items remain pending for the next heartbeat sweep.

## Usage Pattern

### Complete Example: Ship Order Automation

This example automates order shipping. When an `OrderPlaced` event arrives, a TODO item is created. The processor issues a `ShipOrder` command. When the `OrderShipped` event arrives, the TODO item is resolved.

The **spec file** declares the `todoItem`, `command`, sweep config, and
`targetName`. `@@reventless.spec` injects `name`, `module Id`, and `moduleUrl`
from the filename; inside a `*Slice/` folder it also auto-applies DCB tags to
`*Id` fields — never write `@s.matches(...)` by hand:

```rescript title="Order/AutomationSlice/AutoShipOrder.res" showLineNumbers
@@reventless.spec

@schema
type todoItem = {orderId: string}

@schema
type command = ShipOrder({orderId: string})

let maxRetries = 3
let heartbeatInterval = 60
let targetName = "ShipOrder"
```

The **automation file** declares the per-source `Mapping.Make` (with `collect`
and `resolve`), the `mappings` array, and the source-agnostic `process`.
`@@reventless.automation` injects the `Mappings.Make` wrapper (`module type Mapping`)
and DCB tags on the Source module's `*Id` fields:

```rescript title="Order/AutomationSlice/AutoShipOrder_Automation.res" showLineNumbers
@@reventless.automation

// Single DCB source. `name` MUST equal `<pluginName>DcbEventLog` so the dispatch
// resolves it to the topic key the plugin registers under.
module OrderingDcbSource = {
  let name = "OrderingDcbEventLog"
  @schema
  type event =
    | OrderPlaced({orderId: string})
    | OrderShipped({orderId: string})
}

module FromOrderingDcb = Mapping.Make(
  OrderingDcbSource,
  AutoShipOrder,
  {
    open OrderingDcbSource

    let collect = (event, _ctx) =>
      switch event {
      | OrderPlaced({orderId}) => [(orderId, ({orderId: orderId}: AutoShipOrder.todoItem))]
      | OrderShipped(_) => []
      }

    let resolve = event =>
      switch event {
      | OrderShipped({orderId}) => Some(orderId)
      | OrderPlaced(_) => None
      }
  },
)

let mappings: array<module(Mapping)> = [module(FromOrderingDcb)]

let process = (id, _item) => Some((id, ShipOrder({orderId: id})))
```

### Plugin Wiring

You never register or wire AutomationSlices by hand. The plugin generator scans
the `AutomationSlice/` folder and emits the wiring into the **generated**
`Plugin.res` using the two-arg factory `Platform.AutomationSlice.Make(Spec, Automation)`:

```rescript title="src/Plugin.res (generated — do not edit)"
module Make = (Platform: ReventlessInfra.Platform.T) => {
  // AutomationSlices
  module AutoShipOrderSlice = Platform.AutomationSlice.Make(AutoShipOrder, AutoShipOrder_Automation)

  let make = () =>
    Platform.Plugin.make(
      ~name="Ordering",
      ~automationSlices=[module(AutoShipOrderSlice)],
      // ... other components
    )
}
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

## When an item runs out of retries

`process` producing a command that cannot be published moves the item towards its
retry ceiling. On the attempt that spends the budget the row becomes `Abandoned`
and `onExhausted` is consulted:

```rescript
let onExhausted = (_id, _item) => None
```

Return `Some((targetId, command))` to tell the domain, `None` to stay silent. It
is declared either way, because abandonment is an outcome and the framework cannot
publish it for you: the command has to name a target, and which target is exactly
what the slice knows and the framework does not. The row is marked `Abandoned`
regardless — the hook decides only whether anything downstream reacts.

## TODO List Storage

The TODO list is stored in a QueryDb for observability. Each row:

```rescript
type todoStatus = Pending | Processing | Completed | Failed | Abandoned

type todoRow = {
  item: JSON.t,
  status: todoStatus,
  createdAt: string,
  processedAt?: string,
  completedAt?: string,
  retryCount: int,
  maxRetries?: int,
}
```

`Failed` and `Abandoned` are opposite instructions to whoever is reading. A
`Failed` row will be tried again on the next sweep; an `Abandoned` one has spent
its retry budget and no sweep will pick it up. The row carries `maxRetries`
alongside `retryCount` so a caller can read "2 of 3" without knowing a constant
that lives in the Spec. It is optional only because rows written before the field
existed are rehydrated by decoding them.

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

- **[DcbEventLog](/framework/runtime-components/dcbeventlog)** -- Shared event log that AutomationSlice subscribes to
- **[StateChangeSlice](./statechangeslice.md)** -- Processes the commands AutomationSlice produces
- **[StateViewSlice](./stateviewslice.md)** -- Another DCB slice type for read-side projections
- **[CommandTopic](/framework/runtime-components/commandtopic)** -- Receives commands from the processor
- **[EventCollector](/framework/runtime-components/eventcollector)** -- Subscribes to DcbEventLog events
- **[QueryDb](/framework/runtime-components/querydb)** -- Stores the TODO list for observability
- **[EventMapper](/framework/runtime-components/eventmapper)** -- Stateless alternative for plugins using Aggregates
- **[Plugin](./plugin.md)** -- Hosts AutomationSlice via DcbSpec
