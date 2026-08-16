---
title: OutboundTranslationSlice
---

For a short summary of OutboundTranslationSlice, see [Reventless Components Overview.](../component-overview.md)

:::info Framework Implementation
This component follows the Reventless [Component Structure Pattern](/framework/internals/component-structure-pattern), using separate files for interface definitions (`OutboundTranslationSlice.res`), builder logic (`OutboundTranslationSlice_Builder.res`), and callback/handler logic (`OutboundTranslationSlice_Callback.res`).
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

The **OutboundTranslationSlice** implements the Event Modeling **Translation** pattern for outbound external communication. It listens to events from its declared sources, accumulates outbound work items into a TODO list, translates each item by calling an external service, and optionally publishes a command back into the domain.

Those sources default to the plugin's own DcbEventLog — the diagram above — but need
not be. `Spec.sourceNames` also names Aggregates, so an Aggregate's events can
trigger an outbound call; see [Event sources](#event-sources).

## Event Modeling: The Outbound Translation Pattern

In Event Modeling, an **Outbound Translation** handles communication from the system to external services:

```
Event(s) --> TODO List --> Translator --> External System
                                     --> Command (optional)
```

The key difference from AutomationSlice is that the "process" step involves an **external call** (async, may fail) rather than a deterministic command derivation. Each item is translated independently, allowing individual success or failure.

## Purpose and Responsibilities

- **Responsibility**: Collect outbound items from events; call external services for each item via the `translate` function; optionally publish commands back into the domain; track status with per-item retry semantics
- **In**: Events from the sources named in `Spec.sourceNames` — the plugin's own DcbEventLog by default, Aggregates and other DCB logs when declared (subscribed via EventCollector)
- **Out**: External API calls (via `translate`); optional commands to CommandTopic (via `publishJsons`); TODO state synced to QueryDb

## Comparison with SideEffectHandler

| Aspect | SideEffectHandler | OutboundTranslationSlice |
|--------|-------------------|--------------------------|
| **Architecture** | Aggregate-based plugins | Either — DCB by default, Aggregates via `sourceNames` |
| **State tracking** | None -- fire-and-forget | TODO list with status (Pending/Processing/Completed/Failed) |
| **Retry** | Relies on EventCollector retry (entire batch) | Per-item retry with configurable max |
| **Idempotency** | None -- replays cause duplicate calls | Deduplication key prevents double-processing |
| **Visibility** | No queryable state | QueryDb stores full processing history |
| **Command emission** | Never | Optional -- can publish commands back |

**Choose SideEffectHandler** for simple fire-and-forget event reactions where a failed call needs no record.

**Choose OutboundTranslationSlice** when you need tracked, retryable external calls
with full observability. Aggregate-based plugins are no longer a reason to prefer
the other one: name the Aggregate in `sourceNames` and this slice consumes its
events like any other source.

## Component Spec

An OutboundTranslationSlice is **split into two files**:

- `<Name>.res` — the **spec** (`@@reventless.spec`): the `consumedEvent`,
  `outboundItem`, and `inboundCommand` `@schema` types, the sweep config
  (`maxRetries`, `heartbeatInterval`), and `targetName` (`None` for fire-and-forget,
  or `Some("<TargetSlice>")` to publish a command back).
- `<Name>_Translation.res` — the **translation** (`@@reventless.translation`): the
  `collect` function (event → outbound items) and the async `translate` function
  (the external call).

The spec module type the framework expects:

```rescript
module type Spec = {
  // name and moduleUrl are injected by @@reventless.spec — you never write them

  @schema type consumedEvent
  @schema type outboundItem
  @schema type inboundCommand

  let maxRetries: int
  let heartbeatInterval: int
  let targetName: option<string>
  let sourceNames: array<string>
  let externalSystem: option<string>
}
```

`collect` and `translate` live on the `Translation` module. There is no
`DcbEventLogSpec` reference; the slice declares a local `consumedEvent` union
and names its sources in `sourceNames`.

### Spec Fields Explained

| Field | Type | Description |
|-------|------|-------------|
| `consumedEvent` | `@schema type` | The local subset of event variants this slice reacts to |
| `outboundItem` | `@schema type` | Data accumulated for each pending external call |
| `inboundCommand` | `@schema type` | Command type optionally published back after translate. Use `unit` for fire-and-forget |
| `maxRetries` | `int` | Maximum retry attempts for failed items |
| `heartbeatInterval` | `int` | Seconds between heartbeat sweeps for pending/failed items |
| `targetName` | `option<string>` | `None` for fire-and-forget; `Some("<TargetSlice>")` to route the optional command back |
| `sourceNames` | `array<string>` | Event sources to subscribe to. `[]` (the default) means this plugin's own DcbEventLog — see [Event sources](#event-sources) |
| `externalSystem` | `option<string>` | Display name of the foreign system, drawn as an external box in the Event Graph. Auto-injected as `None` |

In the `_Translation.res` file:

| Function | Type | Description |
|----------|------|-------------|
| `collect` | `(consumedEvent, ~sourceId: string) => array<(string, outboundItem)>` | Map an event to zero or more outbound items (id + payload). `~sourceId` is the entity the event was published for |
| `translate` | `(string, outboundItem) => promise<result<...>>` | Call external service; returns success with optional command, or error |

### Event sources

`sourceNames` names the topics this slice's EventCollector subscribes to:

| Value | Subscribes to |
|-------|---------------|
| `[]` | This plugin's own DcbEventLog. The default, and what every slice written before sources existed keeps doing |
| `["Customer"]` | The `Customer` Aggregate's EventTopic — an Aggregate's `Spec.name` |
| `["OrderingDcbEventLog"]` | A DCB log by name, conventionally `"<pluginName>DcbEventLog"` |

Each name is validated against the plugin-wide topic dict at deploy time; a name
that matches nothing fails the build with a message listing the keys that are
available.

Sources are a **flat list**, not the per-source `Mapping` modules an
[AutomationSlice](./automationslice.md) uses. An automation needs a `resolve` per
source — a different event completes the item depending on where it came from —
whereas an outbound item is resolved by its own `translate` succeeding. The only
thing that varies per source is the decode, and the single `consumedEvent` union
already covers that.

The cost of the flat form: two sources that publish an event type of the same
name are indistinguishable to `collect`. Declare only the sources whose events you
actually mean.

### Why `collect` takes `~sourceId`

`collect` receives the envelope's id alongside the decoded event, because the
event alone may not say what it is about:

```rescript
let collect = (event, ~sourceId) =>
  switch event {
  | Registered({address}) => [(`${sourceId}:${address}`, {customerId: sourceId, address})]
  }
```

A DCB event usually names its own subject in the payload — `OrderPlaced({orderId,
…})` — and can ignore the argument. An Aggregate's event generally does not: the
aggregate id is what *addressed* the event, so it is on the envelope rather than
in the payload. Without `~sourceId` an outbound item built from
`Registered({email, address})` would have no way to say which customer it is for.

Note the deduplication key above is `{id}:{address}`, not `{id}`. Keying by the
entity alone would make a later address change look like work already done, and
the corrected address would never be translated.

### The translate Return Values

The `translate` function is the anti-corruption layer -- where user code calls external APIs:

- **`Ok(Some((targetId, command)))`** -- External call succeeded; publish command back into the domain (e.g., confirm payment after calling payment gateway)
- **`Ok(None)`** -- External call succeeded; no command needed (fire-and-forget, e.g., send email notification)
- **`Error(msg)`** -- External call failed; item will be retried up to `maxRetries`

## Usage Pattern

### Example 1: Fire-and-Forget (Send Tracking Email)

The **spec file**. `@@reventless.spec` injects `name`, `module Id`, and
`moduleUrl` from the filename, and inside a `*Slice/` folder auto-applies DCB tags
to `*Id` fields — never write `@s.matches(...)` by hand. `targetName = None`
signals fire-and-forget:

```rescript title="Order/OutboundTranslationSlice/SendTrackingEmail.res" showLineNumbers
@@reventless.spec

@schema
type consumedEvent =
  | OrderShipped({orderId: string, email: string})

@schema
type outboundItem = {orderId: string, email: string}

@schema
type inboundCommand = unit

let maxRetries = 3
let heartbeatInterval = 60
let targetName = None
// This plugin's own DCB event log — `OrderShipped` is a DCB event. The
// annotation is needed because a bare `[]` has no element type to infer.
let sourceNames: array<string> = []
let externalSystem = Some("EmailService")
```

The **translation file** (`@@reventless.translation`) holds `collect` and the
async `translate`. `OrderShipped` carries its own `orderId`, so this `collect`
ignores `~sourceId`:

```rescript title="Order/OutboundTranslationSlice/SendTrackingEmail_Translation.res" showLineNumbers
@@reventless.translation

let collect = (event, ~sourceId as _) =>
  switch event {
  | OrderShipped({orderId, email}) => [(orderId, {orderId, email})]
  }

let translate = async (_id, item) => {
  await EmailService.sendTrackingEmail(item.email, ~orderId=item.orderId)
  Ok(None) // fire-and-forget: no command back
}
```

### Example 2: Command-Back (Process Payment)

Here `targetName = Some("ConfirmPayment")` routes the optional command back into
the domain:

```rescript title="Payment/OutboundTranslationSlice/ProcessPayment.res" showLineNumbers
@@reventless.spec

@schema
type consumedEvent =
  | PaymentRequested({orderId: string, amount: float})

@schema
type outboundItem = {orderId: string, amount: float}

@schema
type inboundCommand = ConfirmPayment({
  orderId: string,
  transactionId: string,
})

let maxRetries = 5
let heartbeatInterval = 30
let targetName = Some("ConfirmPayment")
let sourceNames: array<string> = []
let externalSystem = Some("PaymentGateway")
```

```rescript title="Payment/OutboundTranslationSlice/ProcessPayment_Translation.res" showLineNumbers
@@reventless.translation

let collect = (event, ~sourceId as _) =>
  switch event {
  | PaymentRequested({orderId, amount}) => [(orderId, {orderId, amount})]
  }

let translate = async (id, item) => {
  try {
    let result = await PaymentGateway.charge(item.amount, ~orderId=item.orderId)
    Ok(Some((id, ConfirmPayment({orderId: item.orderId, transactionId: result.transactionId}))))
  } catch {
  | exn =>
    let msg =
      exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("payment failed")
    Error(msg)
  }
}
```

### Plugin Wiring

You never register or wire OutboundTranslationSlices by hand. The plugin generator
scans the `OutboundTranslationSlice/` folder and emits the wiring into the
**generated** `Plugin.res` using the two-arg factory
`Platform.OutboundTranslationSlice.Make(Spec, Translation)`:

```rescript title="src/Plugin.res (generated — do not edit)"
module Make = (Platform: ReventlessInfra.Platform.T) => {
  // OutboundTranslationSlices
  module SendTrackingEmailSlice = Platform.OutboundTranslationSlice.Make(SendTrackingEmail, SendTrackingEmail_Translation)
  module ProcessPaymentSlice = Platform.OutboundTranslationSlice.Make(ProcessPayment, ProcessPayment_Translation)

  let make = () =>
    Platform.Plugin.make(
      ~name="Ordering",
      ~outboundTranslationSlices=[module(SendTrackingEmailSlice), module(ProcessPaymentSlice)],
      // ... other components
    )
}
```

The framework automatically wires the slice to the sources it declared and to the
CommandTopic.

### Example 3: An Aggregate as the source

`sourceNames` names the Aggregate, and `~sourceId` supplies the customer id that
the event payload does not carry:

```rescript title="Customer/OutboundTranslationSlice/GeocodeCustomerAddress.res" showLineNumbers
@@reventless.spec

@schema
type consumedEvent =
  | Registered({email: string, address: string})
  | AddressUpdated({address: string})

@schema
type outboundItem = {customerId: string, address: string}

@schema
type inboundCommand =
  | SetLocation({location: Reventless.GeoPoint.t, resolvedFrom: string})
  | MarkAddressUnresolvable({address: string, reason: string})

// Retries are for a geocoder that is *down*, not for one that has answered. An
// address the service has no match for is settled by publishing a command, not
// by asking three more times.
let maxRetries = 3
let heartbeatInterval = 60
let targetName = Some("Customer")

// The Customer Aggregate, by its `Spec.name`.
let sourceNames = ["Customer"]
let externalSystem = Some("AwsLocation")
```

```rescript title="Customer/OutboundTranslationSlice/GeocodeCustomerAddress_Translation.res" showLineNumbers
@@reventless.translation

let collect = (event, ~sourceId) =>
  switch event {
  | Registered({address}) => [(`${sourceId}:${address}`, {customerId: sourceId, address})]
  | AddressUpdated({address}) => [(`${sourceId}:${address}`, {customerId: sourceId, address})]
  }
```

Note that the slice publishes back into the same Aggregate it reads from. That is
not a cycle: `SetLocation` produces an event this slice does not consume, so the
loop terminates by construction rather than by a guard. Choosing which events a
slice consumes is how you keep it that way.

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
  for each (id, item) in collect(event, ~sourceId=envelope.id):
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
completed: Completed { class: read model }
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
- **[DcbEventLog](/framework/runtime-components/dcbeventlog)** -- Shared event log that OutboundTranslationSlice subscribes to
- **[StateChangeSlice](./statechangeslice.md)** -- Processes the commands OutboundTranslationSlice optionally produces
- **[CommandTopic](/framework/runtime-components/commandtopic)** -- Receives optional commands from the translator
- **[EventCollector](/framework/runtime-components/eventcollector)** -- Subscribes to the topics named in `sourceNames`
- **[QueryDb](/framework/runtime-components/querydb)** -- Stores the TODO list for observability
- **[Plugin](./plugin.md)** -- Hosts OutboundTranslationSlice via DcbSpec
