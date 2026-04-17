---
title: OutboundTranslationSlice
date: 2026-03-03
draft: false
---

For a short summary of OutboundTranslationSlice, see [Reventless Components Overview.](../component-overview.md#outboundtranslationslice)

:::info Framework Implementation
This component follows the Reventless [Component Structure Pattern](/framework/inner-workings/component-structure-pattern), using separate files for interface definitions (`OutboundTranslationSlice.res`), builder logic (`OutboundTranslationSlice_Builder.res`), and callback/handler logic (`OutboundTranslationSlice_Callback.res`).
:::

## Overview

```d2
DcbEventLog: DcbEventLog { class: dcb-event-log }
EventTopic: Event Topic { class: event-topic }
OutboundSlice: OutboundTranslationSlice { class: automation-slice }
TodoQueryDb: TODO List QueryDb { class: query-db }
External: External System { class: external-system }
CommandTopic: Command Topic { class: command-topic }
StateChangeSlice: StateChangeSlice { class: state-change-slice }

DcbEventLog -> EventTopic: publish { class: event-flow }
EventTopic -> OutboundSlice: events { class: event-flow }
OutboundSlice -> TodoQueryDb: sync TODO state { class: projection-flow }
OutboundSlice -> External: "translate (API call)"
External -> OutboundSlice: response
OutboundSlice -> CommandTopic: "commands (optional)" { class: command-flow }
CommandTopic -> StateChangeSlice: commands { class: command-flow }
StateChangeSlice -> DcbEventLog: append { class: event-flow }
```

The **OutboundTranslationSlice** implements the Event Modeling **Translation** pattern for outbound external communication. It listens to events from a shared DcbEventLog, accumulates outbound work items into a TODO list, translates each item by calling an external service, and optionally publishes a command back into the domain.

## Event Modeling: The Outbound Translation Pattern

In Event Modeling, an **Outbound Translation** handles communication from the system to external services:

```
Event(s) --> TODO List --> Translator --> External System
                                     --> Command (optional)
```

The key difference from AutomationSlice is that the "process" step involves an **external call** (async, may fail) rather than a deterministic command derivation. Each item is translated independently, allowing individual success or failure.

## Purpose and Responsibilities

- **Responsibility**: Collect outbound items from events; call external services for each item via the `translate` function; optionally publish commands back into the domain; track status with per-item retry semantics
- **In**: Events from DcbEventLog (subscribed via EventCollector)
- **Out**: External API calls (via `translate`); optional commands to CommandTopic (via `publishJsons`); TODO state synced to QueryDb

## Comparison with SideEffectHandler

| Aspect | SideEffectHandler | OutboundTranslationSlice |
|--------|-------------------|--------------------------|
| **Architecture** | Aggregate-based plugins | DCB-based plugins |
| **State tracking** | None -- fire-and-forget | TODO list with status (Pending/Processing/Completed/Failed) |
| **Retry** | Relies on EventCollector retry (entire batch) | Per-item retry with configurable max |
| **Idempotency** | None -- replays cause duplicate calls | Deduplication key prevents double-processing |
| **Visibility** | No queryable state | QueryDb stores full processing history |
| **Command emission** | Never | Optional -- can publish commands back |

**Choose SideEffectHandler** when you have plugins using Aggregates and need simple fire-and-forget event reactions.

**Choose OutboundTranslationSlice** when you need tracked, retryable external calls with full observability in a DCB-based plugin.

## Component Spec

```rescript
module type Spec = {
  let name: string
  module DcbEventLogSpec: DcbEventLog.Spec

  @schema type outboundItem
  @schema type inboundCommand

  let collect: DcbEventLogSpec.event => array<(string, outboundItem)>
  let translate: (string, outboundItem) => promise<result<option<(string, inboundCommand)>, string>>

  let maxRetries: int
  let heartbeatInterval: int
}
```

### Spec Fields Explained

| Field | Type | Description |
|-------|------|-------------|
| `name` | `string` | Unique identifier for this outbound translation slice |
| `DcbEventLogSpec` | `module(DcbEventLog.Spec)` | Reference to the shared event log spec |
| `outboundItem` | `@schema type` | Data accumulated for each pending external call |
| `inboundCommand` | `@schema type` | Command type optionally published back after translate. Use `unit` for fire-and-forget |
| `collect` | `event => array<(string, outboundItem)>` | Map an event to zero or more outbound items (id + payload) |
| `translate` | `(string, outboundItem) => promise<result<...>>` | Call external service; returns success with optional command, or error |
| `maxRetries` | `int` | Maximum retry attempts for failed items |
| `heartbeatInterval` | `int` | Seconds between heartbeat sweeps for pending/failed items |

### The translate Return Values

The `translate` function is the anti-corruption layer -- where user code calls external APIs:

- **`Ok(Some((targetId, command)))`** -- External call succeeded; publish command back into the domain (e.g., confirm payment after calling payment gateway)
- **`Ok(None)`** -- External call succeeded; no command needed (fire-and-forget, e.g., send email notification)
- **`Error(msg)`** -- External call failed; item will be retried up to `maxRetries`

## Usage Pattern

### Example 1: Fire-and-Forget (Send Tracking Email)

```rescript title="SendTrackingEmail.res"
module DcbEventLogSpec = OrderingEventLog

let name = "SendTrackingEmail"

@schema
type outboundItem = {orderId: string, email: string}

@schema
type inboundCommand = unit

let collect = event =>
  switch event {
  | OrderingEventLog.OrderShipped({orderId, email}) =>
    [(orderId, {orderId, email})]
  | _ => []
  }

let translate = async (_id, item) => {
  await EmailService.sendTrackingEmail(item.email, ~orderId=item.orderId)
  Ok(None)  // fire-and-forget: no command back
}

let maxRetries = 3
let heartbeatInterval = 60
```

### Example 2: Command-Back (Process Payment)

```rescript title="ProcessPayment.res"
module DcbEventLogSpec = OrderingEventLog

let name = "ProcessPayment"

@schema
type outboundItem = {orderId: string, amount: float}

@schema
type inboundCommand = ConfirmPayment({
  orderId: @s.matches(DcbTag.string) string,
  transactionId: string,
})

let collect = event =>
  switch event {
  | OrderingEventLog.PaymentRequested({orderId, amount}) =>
    [(orderId, {orderId, amount})]
  | _ => []
  }

let translate = async (id, item) => {
  try {
    let result = await PaymentGateway.charge(item.amount, ~orderId=item.orderId)
    Ok(Some((id, ConfirmPayment({
      orderId: item.orderId,
      transactionId: result.transactionId,
    }))))
  } catch {
  | exn =>
    let msg = exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("payment failed")
    Error(msg)
  }
}

let maxRetries = 5
let heartbeatInterval = 30
```

### Registering in a DcbSpec

OutboundTranslationSlices are registered alongside other slice types in the Plugin's DcbSpec:

```rescript title="OrderingPlugin.res"
module DcbSpec = {
  @schema type event = OrderingEventLog.event

  let stateChangeSlices = [module(PlaceOrderSlice), module(ShipOrderSlice)]
  let stateViewSlices = [module(OrdersViewSlice)]
  let automationSlices = []
  let outboundTranslationSlices = [
    module(SendTrackingEmailSlice),
    module(ProcessPaymentSlice),
  ]
  let inboundTranslationSlices = []
}
```

### Creating with Platform

```rescript title="ProcessPaymentSlice.res"
module ProcessPaymentSlice = Platform.OutboundTranslationSlice.Make(ProcessPayment)
```

The framework automatically wires the slice to the shared DcbEventLog and CommandTopic.

## Runtime Behavior

### Two-Phase Processing

The OutboundTranslationSlice callback has two phases that execute on each event batch:

```d2
shape: sequence_diagram

DcbEventLog: DcbEventLog { class: dcb-event-log }
EventCollector: EventCollector { class: event-collector }
OutboundSlice: OutboundTranslationSlice { class: automation-slice }
TodoList: TODO List
External: External System { class: external-system }
CommandTopic: Command Topic { class: command-topic }
QueryDb: QueryDb { class: query-db }

DcbEventLog -> EventCollector: new events published
EventCollector -> OutboundSlice: "handleEvents(events)"
OutboundSlice -> OutboundSlice: Phase 1: collect
OutboundSlice -> TodoList: insert Pending items
OutboundSlice -> OutboundSlice: Phase 2: translate each item
OutboundSlice -> TodoList: mark item Processing
OutboundSlice -> External: "Spec.translate(id, item)"
External -> OutboundSlice: result
OutboundSlice -> CommandTopic: "publishJsons (if Ok(Some))" { class: command-flow }
OutboundSlice -> TodoList: mark Completed or Failed
OutboundSlice -> QueryDb: sync TODO state
```

**Phase 1 -- Collect** (runs for each event in the batch):

```
for each event:
  for each (id, item) in collect(event):
    if not exists in TODO list:
      insert {id, item, status: Pending}
```

**Phase 2 -- Translate** (runs after Phase 1, processes each item independently):

```
for each item where status = Pending
  OR (status = Failed AND retryCount < maxRetries):
    mark status = Processing
    match await translate(id, item):
      Ok(Some(targetId, cmd)) -> publish command, mark Completed
      Ok(None) -> mark Completed (fire-and-forget)
      Error(msg) -> mark Failed, increment retryCount
```

### TODO Item Lifecycle

```d2
direction: right

pending: Pending { class: state-view-slice }
processing: Processing { class: command }
completed: Completed { class: read-model }
failed: Failed { class: side-effect }

pending -> processing: translate called { class: command-flow }
processing -> completed: "Ok(Some/None)" { class: projection-flow }
processing -> failed: "Error(msg)" { class: event-flow }
failed -> processing: "retry (count < max)" { class: command-flow }
```

Each TODO item moves through these statuses:

| Status | Description |
|--------|-------------|
| `Pending` | Created by `collect`, waiting to be translated |
| `Processing` | `translate` is being called |
| `Completed` | External call succeeded |
| `Failed` | External call failed -- eligible for retry |

### Heartbeat Handler

A periodic heartbeat (configurable via `heartbeatInterval`) runs **Phase 2 only**, catching:

- Failed items eligible for retry (`retryCount < maxRetries`)
- Items collected in a previous batch but not yet translated

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
  lastError?: string,
}
```

This QueryDb is automatically created by the builder and can be queried via the GraphQL API to inspect pending work and translation history.

## Error Handling

**Phase 1 Errors (collect):**
- Event decoding failures are logged and skipped
- `collect` is a pure function -- exceptions are unexpected but caught

**Phase 2 Errors (translate):**
- `outboundItem` decoding failures are logged, item skipped
- `translate` exceptions are caught and treated as `Error(msg)`
- Command encoding failures mark item as `Failed` with incremented `retryCount`
- Publishing failures mark item as `Failed` for retry
- Individual item failure does **not** affect other items

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
  translatePending: unit => promise<unit>,
}
```

**Resource Naming:**
- Component type: `reventless:OutboundTranslationSlice`
- TODO list QueryDb: `{name}Todo`
- EventCollector: subscribed to DcbEventLog's EventTopic

**Dependencies:**
- DcbEventLog (shared event storage)
- CommandTopic (via `publishJsons` for optional command-back publishing)
- QueryDb (for TODO list persistence)

## Related Components

- **[AutomationSlice](./automationslice.md)** -- Similar TODO list pattern for internal command automation (no external calls)
- **[InboundTranslationSlice](./inboundtranslationslice.md)** -- Complementary component for receiving external input
- **[SideEffectHandler](./sideeffecthandler.md)** -- Simpler fire-and-forget pattern for plugins using Aggregates
- **[DcbEventLog](./dcbeventlog.md)** -- Shared event log that OutboundTranslationSlice subscribes to
- **[StateChangeSlice](./statechangeslice.md)** -- Processes the commands OutboundTranslationSlice optionally produces
- **[CommandTopic](./commandtopic.md)** -- Receives optional commands from the translator
- **[EventCollector](./eventcollector.md)** -- Subscribes to DcbEventLog events
- **[QueryDb](./querydb.md)** -- Stores the TODO list for observability
- **[Plugin](./plugin.md)** -- Hosts OutboundTranslationSlice via DcbSpec
