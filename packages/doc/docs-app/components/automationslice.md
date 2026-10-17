---
title: AutomationSlice
---

For a short summary of AutomationSlice, see [Reventless Components Overview.](../component-overview.md)

:::info Framework Implementation
This component follows the Reventless [Component Structure Pattern](/framework/internals/component-structure-pattern), using separate files for interface definitions (`AutomationSlice.res`), builder logic (`AutomationSlice_Builder.res`), and callback/handler logic (`AutomationSlice_Callback.res`).
:::

:::tip Running on a time
An AutomationSlice can also run on a time: a due time inside an item, a time its spec declares (*every morning at 06:00*), or a time an event sets per entity (*at the hour each customer chose*). See [Running on a time](#running-on-a-time).
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
  `@schema` types, the retry config (`maxRetries`), and
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
  let targetName: string
  // injected as None by @@reventless.spec when the spec declares no time
  let schedule: option<Schedule.time>
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
| `targetName` | `string` | Name of the aggregate or StateChangeSlice that receives the produced command |
| `schedule` | `option<Schedule.time>` | The time the slice runs on, which its `Clock` mapping receives as a `Tick`; `None` (injected when absent) for a slice started by events only. See [Running on a time](#running-on-a-time) |

### The Functions

`collect`, `resolve` and `reschedule` live on each per-source `Mapping` in the
`_Automation.res` file; `process` is source-agnostic and lives at the top level
of that same file.

**`collect`** -- `(sourceEvent, ~sourceId, ctx) => array<(string, todoItem)>`. When an event arrives, `collect` decides whether it creates new TODO items. `ctx.recordedAt` is when the event was recorded, the time a due time is counted from. Each item has a string `id` (used as a deduplication key) and a `todoItem` payload. Returns an empty array for irrelevant events. If an item with the same id already exists, it is skipped (idempotent).

**`resolve`** -- `sourceEvent => option<string>`. When an event arrives, `resolve` checks if it marks an existing TODO item as completed. Returns `Some(itemId)` to mark that item done, or `None` to skip. This closes the automation loop -- the command produced by `process` eventually causes events that `resolve` recognizes.

**`reschedule`** -- `sourceEvent => array<scheduleChange>`. Which of the slice's schedules an event sets (`Set({key, time})`) or clears (`Clear({key})`). A mapping written without it is given `let reschedule = _ => []` by the PPX. See [Schedules set by events](#schedules-set-by-events).

**`process`** -- `(string, todoItem, ~now) => option<(string, command)>`. For each pending item, `process` decides what command to issue. Returns `Some((targetId, command))` to publish a command, or `None` to skip processing (e.g., waiting for more data, or a due time `~now` has not reached). Skipped items remain pending for the next sweep. `~now` is the current time in milliseconds, from Effect's `Clock`; a `process` written without it is given `~now as _` by the `@@reventless.automation` PPX.

## Usage Pattern

### Complete Example: Ship Order Automation

This example automates order shipping. When an `OrderPlaced` event arrives, a TODO item is created. The processor issues a `ShipOrder` command. When the `OrderShipped` event arrives, the TODO item is resolved.

The **spec file** declares the `todoItem`, `command`, sweep config, and
`targetName`. `@@reventless.spec` injects `name`, `module Id`, and `moduleUrl`
from the filename; inside a slice folder it also auto-applies DCB tags to
`*Id` fields — never write `@s.matches(...)` by hand:

```rescript title="Order/Automation/AutoShipOrder.res" showLineNumbers
@@reventless.spec

@schema
type todoItem = {orderId: string}

@schema
type command = ShipOrder({orderId: string})

let maxRetries = 3
let targetName = "ShipOrder"
```

The **automation file** declares the per-source `Mapping.Make` (with `collect`
and `resolve`), the `mappings` array, and the source-agnostic `process`.
`@@reventless.automation` injects the `Mappings.Make` wrapper (`module type Mapping`)
and DCB tags on the Source module's `*Id` fields:

```rescript title="Order/Automation/AutoShipOrder_Automation.res" showLineNumbers
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

    let collect = (event, ~sourceId as _, _ctx) =>
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
the `Automation/` folder and emits the wiring into the **generated**
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

pending: Pending { class: status-pending }
processing: Processing { class: status-active }
completed: Completed { class: status-done }
failed: Failed { class: status-retry }

pending -> processing: "process() returns Some"
processing -> completed: "resolve() matches"
processing -> failed: publish error
failed -> processing: "retry (count < max)"
pending -> completed: "resolve() before process"
```

Each TODO item moves through these statuses:

| Status | Description |
|--------|-------------|
| `Pending` | Created by `collect`, waiting to be processed |
| `Processing` | `process` returned a command, waiting for resolution event |
| `Completed` | `resolve` matched -- work is done |
| `Failed` | Command publishing failed, or no resolving event came within 15 minutes -- eligible for retry |
| `Abandoned` | The retry budget is spent -- no sweep picks it up again |

### Heartbeat Handler

A sweep runs **Phase 2 only** every five minutes, one for all automations, on AWS
and locally (where `REVENTLESS_LOCAL_SWEEP_SECONDS` shortens it). It picks up:

- Items collected in a previous batch where `process` returned `None` (waiting for more data)
- Failed items eligible for retry (`retryCount < maxRetries`)

An item whose command was published but whose resolving event never came is sent
again once it has been `Processing` for 15 minutes; that counts as a failed attempt,
so it ends `Abandoned` like any other once `maxRetries` is spent.

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

## Running on a time

An automation is started by events, but some work is about **when**: an order not
shipped in three days is cancelled, a report is requested every morning, a customer
gets a digest at the hour they chose. There is no separate component for this. The
same slice runs on a time, in one of three ways:

| Way | The time lives in | Example |
|---|---|---|
| **A due time** | the to-do item; `process` waits for `~now` to reach it, and the sweep offers it every five minutes | cancel an order not shipped in three days |
| **A declared schedule** | the spec: `let schedule` | the demand report every morning at 06:00 |
| **Schedules set by events** | rows the slice keeps, one per key, set and cleared by `reschedule` | a digest at the time each customer chose |

The platform only knows **when**. Its Scheduler (EventBridge Scheduler on AWS,
timers locally) fires, and the slice receives a `Tick({key, at})` from the
framework's `Clock` source: which of its schedules fired, and the time it was
scheduled for. What the tick means stays in the slice's mappings and `process`,
exactly as for an event.

### Three words

| Word | Names |
|---|---|
| **Scheduler** | the platform's part that fires at a time |
| **schedule** | one key and one time held by one slice |
| **time** | when a schedule fires: `Every` an interval, `Calendar` a wall-clock time, or `Once` a single moment (`Schedule.time`) |
| **Clock**, **Tick** | the source a slice maps to receive its schedules' firings, and its one event |

### A due time

No schedule at all: `collect` counts the due time from when the event was recorded
(`ctx.recordedAt`), and `process` returns `None` until `~now` reaches it. The item
stays pending, and each sweep offers it again. Precise to the sweep, five minutes.
From the online shop's
[CancelUnshippedOrder_Automation.res](https://github.com/ReventlessDev/reventless-core/blob/alpha/examples/online-shop-hybrid/ordering/src/Order/Automation/CancelUnshippedOrder_Automation.res):

```rescript title="Order/Automation/CancelUnshippedOrder_Automation.res (excerpt)"
let collect = (event, ~sourceId as _, ctx: Reventless.AutomationSlice.context) =>
  switch (event, ctx.recordedAt) {
  | (OrderPlaced({orderId, shippingMethod: Standard}), Some(placedAt)) => [
      (
        orderId->OrderId.toString,
        ({orderId, dueAt: placedAt +. shippingWindowMs}: CancelUnshippedOrder.todoItem),
      ),
    ]
  | _ => []
  }

let process = (id, item: CancelUnshippedOrder.todoItem, ~now) =>
  now >= item.dueAt ? Some((id, CancelOrder({orderId: item.orderId}))) : None
```

`OrderShipped` or `OrderCancelled` resolves the item first, and nothing is sent.

### A declared schedule

The spec declares the time, and a mapping reads the `Clock`. Each tick makes the
day's item; `Clock.itemId(key, at)` names it by the key and the scheduled minute in
UTC (`default@2026-10-16T06:00Z`), so the same tick delivered twice makes one item.

```rescript title="Catalog/Automation/DemandReport.res"
@@reventless.spec

@schema
type todoItem = {day: float}

@schema
type command = RequestDemandReport({day: float})

let maxRetries = 3
let targetName = "ReportSettings"
let schedule = Some(Reventless.Schedule.Calendar({calendar: Daily({hour: 6, minute: 0})}))
```

```rescript title="Catalog/Automation/DemandReport_Automation.res (excerpt)"
module FromClock = Mapping.Make(
  Reventless.Clock,
  DemandReport,
  {
    open Reventless.Clock
    let collect = (Tick({key, at}), ~sourceId as _, _ctx) => [
      (itemId(key, at), ({day: at}: DemandReport.todoItem)),
    ]
    let resolve = _ => None
  },
)
```

The declared schedule is held under the key `Clock.defaultKey` (`"default"`). A
slice that maps the `Clock` but declares no schedule, and reads no event that could
set one, is refused when the plugin is assembled: no tick would ever reach it.

### Schedules set by events

Often the time is data. A mapping's `reschedule` says which schedules an event sets
or clears, by key. A key per entity gives each one its own time; the tick carries
the key back, so `collect` knows whose time came. From the shop's
[MarketingDigest_Automation.res](https://github.com/ReventlessDev/reventless-core/blob/alpha/examples/online-shop-hybrid/ordering/src/Notification/Automation/MarketingDigest_Automation.res):

```rescript title="Notification/Automation/MarketingDigest_Automation.res (excerpt)"
module FromClock = Mapping.Make(
  Reventless.Clock,
  MarketingDigest,
  {
    open Reventless.Clock
    let collect = (Tick({key, at}), ~sourceId as _, _ctx) => [
      (itemId(key, at), ({recipientId: key}: MarketingDigest.todoItem)),
    ]
    let resolve = _ => None
  },
)

// in the mapping over the ordering log
let reschedule = event =>
  switch event {
  | DigestTimeChosen({recipientId, hour, minute, zone}) => [
      Set({key: recipientId, time: dailyAt(~hour, ~minute, ~zone)}),
    ]
  | NotificationUnsubscribed({recipientId, category: Marketing, channel: Email}) => [
      Clear({key: recipientId}),
    ]
  | _ => []
  }
```

- **`Set` replaces** the key's time; the last one wins. **`Clear`** of a key with no
  schedule does nothing.
- **An event may replace the declared time** by setting `default`, or stop it by
  clearing `default`. A later deploy does not put the declared time back: the
  declaration only fills a key no event has touched.
- **A time that cannot fire** (a 25th hour, an unknown zone) is refused, logged, and
  changes nothing.

A once-only time suits a reminder: `Once({moment: After(Minutes(10))})` is counted
from when the event was recorded, and its schedule is removed when its tick arrives:

```rescript
let reschedule = event =>
  switch event {
  | OrderPlaced({orderId}) => [Set({key: orderId, time: Once({moment: After(Minutes(10))})})]
  | OrderShipped({orderId}) => [Clear({key: orderId})]
  }
```

### Why `resolve` still matters

A tick makes an item and `process` sends its command, as for any event. The item is
done only when an event resolves it; one left `Processing` is sent again after 15
minutes, up to `maxRetries`. The digest's request carries the item id as its
`reference`, and every outcome of the request (sent, suppressed, undeliverable,
deferred) resolves it by that reference.

### Where the schedules live

- **The rows are the truth.** A slice that maps the `Clock` gets a second store,
  `{name}Schedule`, with a row per key: `key`, `time` (the `Schedule.time` as JSON
  text, an `After` already counted from its event), `setBy` (the event's id, or
  `declared`) and `setAt`. Its list query answers *when does it run, and who set it*.
- **The platform follows them.** An event's change is stored first, then the
  platform is told. At deploy on AWS, and when the slice starts locally, a reconcile
  writes the declared time into the rows, puts on the platform what it is missing, and
  removes what the rows do not hold; a once-only time already past is not made again.
- **On AWS** each stack has one schedule group, and a slice's schedule is named
  `<slice>.<key>`, or hashed when that is longer than 64 characters or holds a
  character EventBridge refuses. The schedule invokes the automation Lambda.
- **Daylight saving** follows AWS on both platforms: a calendar time in the hour
  skipped in spring does not fire that day, and one in the repeated hour fires once.

### Testing

The GWT DSL fixes the time. `atTime(t)` dates the given events, `whenSweep(~now)`
runs the sweep at a time, `whenTick(~key, ~at)` delivers a tick, and `thenSchedules`
compares the rows by key, with the declared time in them unless an event replaced it:

```rescript
test("a Standard order not shipped after three days is cancelled", () =>
  givenEvents([Ordering.event(OrderPlaced({orderId: o1, shippingMethod: Standard}))])
  ->atTime(day0)
  ->whenSweep(~now=day0 +. 3. *. day)
  ->thenCommands([(orderRef, CancelOrder({orderId: o1}))])
)

test("each recipient's choice is their own schedule, read on their own clock", () =>
  givenEvents([
    Ordering.event(DigestTimeChosen({recipientId: "c1", hour: 18, minute: 0, zone: ""})),
    Ordering.event(
      DigestTimeChosen({recipientId: "c2", hour: 7, minute: 30, zone: "Europe/Berlin"}),
    ),
  ])
  ->whenSweep
  ->thenSchedules([("c1", utc18), ("c2", berlin730)])
)
```

### Which to use

```d2
direction: down

starts: "What starts it?" { shape: diamond }
minute: "Must it be on the minute?" { shape: diamond }
fixed: "Is the time fixed in code?" { shape: diamond }
many: "One time for the app, or one per entity?" { shape: diamond }

due: "A due time\nan item the sweep offers" { class: automation-slice }
once: "Once\nSet at the event, Clear on the cancelling one" { class: automation-slice }
declared: "A declared schedule\nlet schedule" { class: automation-slice }
default: "Set the key default\nfrom an event" { class: automation-slice }
perEntity: "Set a key per entity\nfrom an event" { class: automation-slice }

starts -> minute: an event, some time later
minute -> due: no
minute -> once: yes
starts -> fixed: the clock
fixed -> declared: yes
fixed -> many: "no, it is data"
many -> default: one
many -> perEntity: per entity
```

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
| **Heartbeat** | None | Periodic sweep for pending and failed items |
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
  // only for a slice that maps the Clock
  schedulesDb?: QueryDb.outputs,
}

type operations = {
  enqueueEvent: EventCollector.enqueueEvent,
  processPending: unit => promise<unit>,
  tick: (~key: string, ~at: float) => promise<unit>,
  reconcileSchedules: unit => promise<unit>,
  rebuildSchedules: array<JSON.t> => promise<unit>,
}
```

**Resource Naming:**
- Component type: `reventless:AutomationSlice`
- TODO list QueryDb: `{name}Todo`
- Schedules QueryDb: `{name}Schedule`, for a slice that maps the `Clock`
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
