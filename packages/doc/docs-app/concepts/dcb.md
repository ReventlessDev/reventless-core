# DCB (Dynamic Consistency Boundary)

The Plugin component supports an optional DCB (Dynamic Consistency Boundary) event log shared across multiple state change slices. All slices in a plugin read from and write to the same event log, with optimistic concurrency control enforced per command.

:::tip Full usage guide
This page explains the concept. For the hands-on patterns — tags, decision
models, multi-entity commands — see the [DCB usage guide](../dcb-usage).
:::

## Command Flow

```d2
Client: Client { class: client }
SQS: "SQS Queue\n(DCB Command Topic)" { class: command-topic }
Handler: "filteringHandler\n(Lambda Function)"
Slice1: CreateItem Slice { class: state-change-slice }
Slice2: RenameItem Slice { class: state-change-slice }
Handler3: NoOp Handler
EventLog: "DcbEventLog\n(Shared Event Log)" { class: dcb-event-log }
ViewSlice: "StateViewSlice\n(Projection)" { class: state-view-slice }
QueryDb: "QueryDb\n(Read Model)" { class: query-db }
Read: 1. read events
Evolve: 2. evolve
Decide: 3. decide
Append: "4. append\n(optimistic concurrency)"

Client -> SQS: { class: command-flow }
SQS -> Handler: { class: command-flow }
Handler -> Slice1: { class: command-flow }
Handler -> Slice2: { class: command-flow }
Handler -> Handler3: { class: command-flow }
Slice1 -> EventLog: { class: event-flow }
Slice2 -> EventLog: { class: event-flow }
EventLog -> ViewSlice: { class: event-flow }
ViewSlice -> QueryDb: { class: projection-flow }
EventLog -> Read
Read -> Evolve
Evolve -> Decide
Decide -> Append
```

The DCB command topic is a standard SQS queue by default — sync slices (the default) return `CommandAccepted` / `CommandRejected`. Slices tagged with `@@reventless.async` use a separate FIFO queue and return `CommandPending`; the plugin generator renders `Platform.StateChangeSlice.MakeAsync(...)` for those and `Make(...)` for the rest, and both types end up in the same `~stateChangeSlices` array at the `Plugin.make` call site. The `filteringHandler` in the Lambda routes each message by its `TAG` field to whichever state change slices handle that command type; both queues share the same handler registry.

## Slice Shapes

Slices are passed directly to `Plugin.make` — there is no `DcbSpec` or `DcbEventLogSpec` wrapper module. Each slice is a pair of files: a spec file declaring its types and a body file holding the logic. A slice declares its **own** `consumedEvent` (the events it reads to rebuild state) and `event` (the events it produces); the framework derives the DCB query from the `*Id` fields, which the PPX tags automatically inside `*Slice/` folders.

### StateChangeSlice

The spec file (`<Name>.res`, `@@reventless.spec`) declares `consumedEvent`, `command`, `error`, and `event`. The behavior file (`<Name>_Behavior.res`, `@@reventless.behavior`) declares `state`, `initialState`, `evolve`, and `decide`:

```rescript title="CreateItem.res — conceptual shape"
@@reventless.spec

@schema type consumedEvent = ItemCreated
@schema type command = CreateItem({itemId: string, name: string})
@schema type error = ItemAlreadyExists
@schema type event = ItemCreated({itemId: string, name: string})
```

```rescript title="CreateItem_Behavior.res — conceptual shape"
@@reventless.behavior

type state
let initialState: state
let evolve: (state, consumedEvent) => state
let decide: (state, command) => result<array<event>, error>
```

### StateViewSlice

The spec file (`<Name>.res`, `@@reventless.spec`) declares `consumedEvent` and the read-model `state`. The projection file (`<Name>_Projection.res`, `@@reventless.projection`) declares `project`, which receives a `consumed` envelope `{event, meta, recordedAt}`:

```rescript title="ItemView.res / ItemView_Projection.res — conceptual shape"
@schema type consumedEvent  // the events this view reads
@schema type state          // the read-model row shape

let project: Reventless.StateViewSlice.consumed<consumedEvent> => array<Reventless.Projection.action<string, state>>
```

## Usage

### 1. Define a state change slice

The slice declares its own `consumedEvent` and `event` types — there is no shared event-log spec. Inside a `StateChangeSlice/` folder the PPX auto-applies `@s.matches(Reventless.DcbTag.string)` to every `*Id` field, so the event log is queried by those values to rebuild state. For cross-entity queries, use a `*Id: array<string>` field; the runtime builds per-element OR clauses automatically.

```rescript title="CreateItem.res"
@@reventless.spec

@schema
type consumedEvent =
  | ItemCreated

@schema
type command =
  | CreateItem({itemId: string, name: string})

@schema
type error = ItemAlreadyExists

@schema
type event =
  | ItemCreated({itemId: string, name: string})
```

```rescript title="CreateItem_Behavior.res"
@@reventless.behavior

type state = {exists: bool}
let initialState = {exists: false}

let evolve = (_state, event) =>
  switch event {
  | ItemCreated => {exists: true}
  }

let decide = (state, command) =>
  switch command {
  | CreateItem({itemId, name}) =>
    if state.exists {
      Error(ItemAlreadyExists)
    } else {
      Ok([ItemCreated({itemId, name})])
    }
  }
```

A second slice on the same event log reads more of the shared history via its own `consumedEvent`:

```rescript title="RenameItem.res"
@@reventless.spec

@schema
type consumedEvent =
  | ItemCreated({name: string})
  | ItemRenamed({name: string})

@schema
type command =
  | RenameItem({itemId: string, name: string})

@schema
type error = ItemNotFound

@schema
type event =
  | ItemRenamed({itemId: string, name: string})
```

```rescript title="RenameItem_Behavior.res"
@@reventless.behavior

type state = {exists: bool, currentName: option<string>}
let initialState = {exists: false, currentName: None}

let evolve = (state, event) =>
  switch event {
  | ItemCreated({name}) => {exists: true, currentName: Some(name)}
  | ItemRenamed({name}) => {...state, currentName: Some(name)}
  }

let decide = (state, command) =>
  switch command {
  | RenameItem({itemId, name}) =>
    if !state.exists {
      Error(ItemNotFound)
    } else {
      Ok([ItemRenamed({itemId, name})])
    }
  }
```

### 2. Wire the slices

Wiring lives in the generated `Plugin.res` as two-argument functor calls — spec first, behavior second. The shared CommandTopic and event log are provisioned by the plugin at deploy time.

```rescript title="Plugin.res (generated)"
module CreateItemSlice = Platform.StateChangeSlice.Make(CreateItem, CreateItem_Behavior)
module RenameItemSlice = Platform.StateChangeSlice.Make(RenameItem, RenameItem_Behavior)
```

### 3. Create the plugin

```rescript title="Plugin.res (generated)"
// Inside the plugin's Make functor:
let make = () =>
  Platform.Plugin.make(
    ~name="MyPlugin",
    ~heartbeatInterval=5,
    ~stateChangeSlices=[module(CreateItemSlice), module(RenameItemSlice)],
    ~stateViewSlices=[module(ItemViewSlice)],
    // ...other component arrays...
  )
```

:::info Framework Implementation
For details on how DCB is implemented inside the framework — the deploy-time plugin builder, schema-based handler registration, filtering handler internals, and design decisions — see the [Framework Developer Guide](/framework/architecture/dcb).
:::
