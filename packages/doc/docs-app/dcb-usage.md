---
title: DCB Usage
---

# DCB Usage

The Plugin component supports an optional DCB (Dynamic Consistency Boundary) event log shared across multiple slices. All slices in a plugin read from and write to the same event log, with optimistic concurrency control enforced per command.

Each slice declares its own `consumedEvent` and `event` types independently — there is no shared event union. The framework validates compatibility between producers and consumers at build time via `DcbValidation`.

## Command Flow

```
Client → SQS (DCB Command Topic) → filteringHandler
                                       │
                      ┌────────────────┼────────────────┐
                      ▼                ▼                ▼
               AddProduct        RenameCategory     NoOp handler
               handler            handler           (registered by
               (registered by     (registered by    their Spec.commandSchema)
               AddProductSlice)   RenameCategorySlice)
                      │                │
                      └────────┬───────┘
                               ▼
                    DcbEventLog (shared, one per plugin)
                    readStream → evolve → decide → append
                               │
                               ▼
                    StateViewSlice (projects events to QueryDb)
```

One SQS FIFO queue per plugin receives all commands. The `filteringHandler` in the Lambda routes each message by its `TAG` field to whichever state change slices handle that command type. Slices that don't handle a command type are never called.

## Module Types

### DCB Slice Parameters on `Plugin.make`

DCB slices are passed directly as optional labeled arrays to `Plugin.make`. No shared event type — each slice brings its own schemas. When any slice array is non-empty, a shared DCB EventLog is provisioned automatically.

```rescript
~stateChangeSlices: array<module(StateChangeSlice.T)>=?,
~stateViewSlices: array<module(StateViewSlice.T)>=?,
~automationSlices: array<module(AutomationSlice.T)>=?,
~outboundTranslationSlices: array<module(OutboundTranslationSlice.T)>=?,
~inboundTranslationSlices: array<module(InboundTranslationSlice.T)>=?,
```

Empty arrays can simply be omitted (all args are optional).

The channel choice (sync vs. async) is encoded in the slice spec via PPX, not in a separate array:
- **Default — sync.** Spec files without any flag get `Platform.StateChangeSlice.Make(Spec, Spec_Behavior)` from the plugin generator, backed by a standard SQS queue; mutation waits for `decide` inline and returns `CommandAccepted` or `CommandRejected` immediately.
- **Opt-in — async.** Add `@@reventless.async` at the top of the slice spec file. The generator emits `Platform.StateChangeSlice.MakeAsync(Spec, Spec_Behavior)`, backed by a FIFO SQS queue; mutation returns `CommandPending` and the command is processed asynchronously. Use for slices where throughput requirements make synchronous per-request replay impractical.

Both variants go in the same `~stateChangeSlices` array. Commands are routed by type name to whichever handler registered for them, regardless of which queue they arrived on.

### `StateChangeSlice.Spec`

Each slice independently declares its `consumedEvent` (what it reads) and `event` (what it writes). These need not be the same type — a slice can consume a payload-less variant (e.g., `| ProductAdded`) and produce a full variant (e.g., `| ProductAdded({productId, name, ...})`).

```rescript
module type Spec = {
  // name and moduleUrl are injected by @@reventless.spec — you never write them

  type state
  let initialState: state

  @schema
  type consumedEvent

  let evolve: (state, consumedEvent) => state

  @schema
  type command

  @schema
  type error

  @schema
  type event

  let decide: (state, command) => result<array<event>, error>
}
```

The `@schema` annotation auto-generates sury schemas: `consumedEventSchema`, `commandSchema`, `errorSchema`, `eventSchema`.

### `StateViewSlice.Spec`

```rescript
module type Spec = {
  // name and moduleUrl are injected by @@reventless.spec — you never write them

  @schema
  type state

  @schema
  type consumedEvent

  let project: consumedEvent => array<Projection.action<string, state>>
}
```

Note: `project` takes only the event (not `option<state>`). Use `Update(id, fn)` for state-dependent projections.

### `AutomationSlice.Spec`

Automation slices watch events and generate commands — enabling event-driven workflows within the DCB.

```rescript
module type Spec = {
  // name and moduleUrl are injected by @@reventless.spec — you never write them

  @schema
  type todoItem

  @schema
  type command

  let maxRetries: int
  let heartbeatInterval: int
  let targetName: string
}
```

`collect`, `resolve`, and `process` live on the per-source `Mapping`, not the Spec — the framework derives the consumed-event set from each mapping's `sourceEventSchema`, so there is no manually-declared `consumedEvent` union. `targetName` names the aggregate or StateChangeSlice that receives the produced command.

### `OutboundTranslationSlice.Spec`

Translates internal events to external side-effects, producing commands that feed back into the DCB.

```rescript
module type Spec = {
  // name and moduleUrl are injected by @@reventless.spec — you never write them

  @schema
  type consumedEvent

  @schema
  type outboundItem

  @schema
  type inboundCommand

  let maxRetries: int
  let heartbeatInterval: int
  let targetName: option<string>
}
```

`collect` and `translate` live on the `Translation` module, not the Spec. `targetName` names the aggregate or StateChangeSlice that receives the inbound command, or `None` for fire-and-forget.

### `InboundTranslationSlice.Spec`

Translates external inputs into DCB commands.

```rescript
module type Spec = {
  // name and moduleUrl are injected by @@reventless.spec — you never write them

  @schema
  type externalInput

  @schema
  type command

  let targetName: string
  // commandAuthorization is injected by @@reventless.spec (default AllowAuthenticated)
}
```

`translate` lives on the `Translation` module, not the Spec. `targetName` names the aggregate or StateChangeSlice that receives the produced command.

### `StateChangeSlice.T`

```rescript
module type T = {
  module Spec: Reventless.StateChangeSlice.Spec
  type component = Component.t<t, outputs, operations>
  let make: (
    ~dcbEventLog: DcbEventLog.component,
    ~publishJsons: Pulumi.Output.t<CommandTopic.publishJsons>,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
```

### `StateViewSlice.T`

```rescript
module type T = {
  module Spec: Reventless.StateViewSlice.Spec
  type component = Component.t<t, outputs, operations>
  let make: (
    ~dcbEventLog: DcbEventLog.component,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
```

### `CommandTopic.T` (relevant additions)

```rescript
module type T = {
  // ...existing fields...

  // Register a JSON handler in the global registry under each command type name
  let registerHandler: (
    ~schema: S.t<unknown>,
    ~handler: jsonCommandsHandler,
    ~typeNames: array<string>,
  ) => unit

  // Returns the routing handler output for Lambda runtime connection
  let makeFilteringHandler: (
    component,
  ) => Pulumi.Output.t<Runtime.eventHandler<callbackEvent, 'context, unit>>

  // ...make, connect, makeHandler...
}
```

## Usage

### 1. Define state change slice specs

Each slice is a pair of files in a `StateChangeSlice/` folder. The spec file declares the slice's own `consumedEvent` (what it reads) and `event` (what it writes) — no shared event log spec module is needed. The PPX auto-injects `let name`, `module Id`, `let moduleUrl`, and applies `@s.matches(Reventless.DcbTag.string)` to every `*Id` field.

```rescript
// AddProduct.res
@@reventless.spec

@schema
type consumedEvent = ProductAdded

@schema
type command =
  | AddProduct({productId: string, name: string, description: string, price: float})

@schema
type error = ProductAlreadyExists

@schema
type event =
  | ProductAdded({productId: string, name: string, description: string, price: float})
```

The behavior file (`@@reventless.behavior`) holds `state`, `initialState`, `evolve`, and `decide`. It auto-injects `open Spec` and `module Spec`:

```rescript
// AddProduct_Behavior.res
@@reventless.behavior

type state = {exists: bool}
let initialState = {exists: false}

let evolve = (_state, event) =>
  switch event {
  | ProductAdded => {exists: true}
  }

let decide = (state, command) =>
  switch command {
  | AddProduct({productId, name, description, price}) =>
    if state.exists {
      Error(ProductAlreadyExists)
    } else {
      Ok([ProductAdded({productId, name, description, price})])
    }
  }
```

Note: `consumedEvent` here is a payload-less `| ProductAdded` — it only needs the TAG to know the event happened. The `event` type carries the full payload. The framework validates at build time that every `consumedEvent` TAG has a matching producer.

Auto-tagged `*Id` fields become DCB tags — the event log is queried by these values to rebuild state. Each event's first tag is also used as the DynamoDB partition key (see [Event Log Partitioning](#event-log-partitioning) below).

### Hiding Commands from the API (`@noApi`)

Commands are automatically exposed as GraphQL mutations and MCP tools. Use `@noApi` to hide internal commands that should only be triggered by automations or admin workflows.

**Variant-level — hide specific commands:**
```rescript
@schema
type command =
  | CancelOrder({orderId: string})           // Public API
  | @noApi ReopenOrder({orderId: string})   // Internal only
```

**Type-level — hide entire command type:**
```rescript
// Recorded from an extension reacting to another plugin's events, not by a client
@schema @noApi
type command =
  | RecordDemand({@partitionTag productId: string, orderId: string})
  | RevokeDemand({@partitionTag productId: string, orderId: string})
```

The `@noApi` annotation prevents commands from appearing in:
- GraphQL mutations
- MCP tool definitions
- API documentation

The command still executes normally when called programmatically or by internal automations.

### 2. Define state view slice specs

A view slice is two files in a `StateViewSliceStream/` folder. The spec file declares `consumedEvent` and the read-model `state`:

```rescript
// Categories.res
@@reventless.spec

@schema
type consumedEvent =
  | CategoryAdded({categoryId: string, name: string})
  | CategoryRenamed({categoryId: string, name: string})
  | CategoryArchived({categoryId: string})

@schema
type state = {categoryId: string, name: string, archived: bool}
```

The projection file (`@@reventless.projection`) declares a one-argument `project`; `Set`/`Update`/`Delete` are in scope without a prefix:

```rescript
// Categories_Projection.res
@@reventless.projection

let project = event =>
  switch event {
  | CategoryAdded({categoryId, name}) => [Set(categoryId, {categoryId, name, archived: false})]
  | CategoryRenamed({categoryId, name}) => [Update(categoryId, state => {...state, name})]
  | CategoryArchived({categoryId}) => [Update(categoryId, state => {...state, archived: true})]
  }
```

### 3. Wire slices via the Platform

`src/Plugin.res` is **auto-generated** by `generate-plugin` (from `reventless-spec`) before each build — no hand-authored composition root needed. The generator discovers all slice specs from their parent folder names and pairs each spec with its body file via a two-argument functor call:

```rescript
// AUTO-GENERATED — do not edit. Run `npm run generate` to update.
module Make = (Platform: ReventlessInfra.Platform.T) => {
  // StateChangeSlices
  module AddProductSlice = Platform.StateChangeSlice.Make(AddProduct, AddProduct_Behavior)
  module ChangeProductNameSlice = Platform.StateChangeSlice.Make(ChangeProductName, ChangeProductName_Behavior)
  module AddCategorySlice = Platform.StateChangeSlice.Make(AddCategory, AddCategory_Behavior)
  module RenameCategorySlice = Platform.StateChangeSlice.Make(RenameCategory, RenameCategory_Behavior)
  module ArchiveCategorySlice = Platform.StateChangeSlice.Make(ArchiveCategory, ArchiveCategory_Behavior)

  // StateViewSliceStreams
  module ProductsStreamSlice = Platform.StateViewSliceStream.Make(Products, Products_Projection)
  module CategoriesStreamSlice = Platform.StateViewSliceStream.Make(Categories, Categories_Projection)

  // InboundTranslationSlices
  module ImportProductSlice = Platform.InboundTranslationSlice.Make(ImportProduct, ImportProduct_Translation)

  // ...
```

### 4. Create the plugin

Pass slice arrays directly to `Plugin.make`. Empty arrays can be omitted.

```rescript
let make = () =>
  Platform.Plugin.make(
    ~name="Catalog",
    ~heartbeatInterval=5,
    ~stateChangeSlices=[
      module(AddProductSlice),
      module(ChangeProductNameSlice),
      module(AddCategorySlice),
      module(RenameCategorySlice),
      module(ArchiveCategorySlice),
    ],
    ~stateViewSlices=[
      module(ProductsStreamSlice),
      module(CategoriesStreamSlice),
    ],
    ~inboundTranslationSlices=[module(ImportProductSlice)],
  )
```

If a slice has very high write contention (e.g. a global counter or a hot partition), tag its spec file with `@@reventless.async`. Its mutations return `CommandPending` instead of `CommandAccepted`:

```rescript title="GlobalCounter.res"
@@reventless.spec
@@reventless.async

@schema
type consumedEvent = ...

@schema
type command = ...

@schema
type error = ...

@schema
type event = ...
```

The plugin generator then emits `Platform.StateChangeSlice.MakeAsync(GlobalCounter, GlobalCounter_Behavior)` for that slice and the standard `Make(...)` for the rest — both share the same `~stateChangeSlices` array in the generated `Plugin.res`:

```rescript
// AUTO-GENERATED Plugin.res — for reference only
module AddProductSlice = Platform.StateChangeSlice.Make(AddProduct, AddProduct_Behavior)
module GlobalCounterSlice = Platform.StateChangeSlice.MakeAsync(GlobalCounter, GlobalCounter_Behavior)  // FIFO queue, CommandPending

Platform.Plugin.make(
  ~name="Catalog",
  ~heartbeatInterval=5,
  ~stateChangeSlices=[
    module(AddProductSlice),
    module(GlobalCounterSlice),   // high contention — async via @@reventless.async
  ],
  ...
)
```

## Plugin Outputs

```rescript
type outputs = {
  // ...existing outputs...
  dcbEventLog: Pulumi.Output.t<option<DcbEventLog.outputs>>,
  stateChangeSlices: Pulumi.Output.t<dict<StateChangeSlice.outputs>>,
  stateViewSlices: Pulumi.Output.t<dict<StateViewSlice.outputs>>,
}
```

- `dcbEventLog`: `Some(outputs)` when any slice array is non-empty, `None` otherwise
- `stateChangeSlices`: keyed by `Spec.name`, contains resources for each slice
- `stateViewSlices`: keyed by `Spec.name`, contains resources and queryDb for each slice

## Architecture

### Deploy-Time Setup

When DCB is configured, `Dcb_Builder.Make.construct` (invoked by `Plugin_Builder`) does the following:

1. **Validates event compatibility** — `DcbValidation.validateProducedAndConsumed` checks that every consumed event TAG has a matching producer, payloads are equivalent across producers, and consumed fields are subsets of produced fields
2. **Extracts tagged fields** from all slices' schemas to determine DynamoDB secondary index names
3. **Derives the partition tag** via `DcbTag.derivePartitionTag` — auto-selects when unambiguous, requires `@partitionTag` annotation when a variant has multiple tags
4. **Creates one `DcbEventLog`** using the plugin name, extracted indexes, and partition tag
5. **Creates the sync `DcbCommandTopic`** (standard SQS) — provisioned if any sync slices present
6. **Creates the async `DcbCommandTopic`** (FIFO SQS) — only provisioned if any `MakeAsync` slices are present
7. **Constructs each sync `StateChangeSlice`** — passes sync `publishJsons`; each slice registers its JSON handler in the global registry
8. **Constructs each async `StateChangeSlice`** — passes async `publishJsons`; handlers go into the same global registry
9. **Constructs each `StateViewSlice`** — each slice gets its own QueryDb and subscribes to DcbEventLog events
10. **Constructs AutomationSlices, OutboundTranslationSlices, InboundTranslationSlices**
11. **Calls `makeFilteringHandler`** on both CommandTopics — both use the same global handler registry
12. **Creates one Lambda per CommandTopic** that has slices assigned to it

```rescript
// Inside Dcb_Builder.Make.construct:

// 1. Validation
let produced = stateChangeSlices->Array.map(
  (module(Sc: StateChangeSlice.T)) =>
    (Sc.Spec.name, Sc.Spec.eventSchema->S.castToUnknown)
)
let consumed = stateChangeSlices->Array.map(
  (module(Sc: StateChangeSlice.T)) =>
    (Sc.Spec.name, Sc.Spec.consumedEventSchema->S.castToUnknown)
)->Array.concat(
  stateViewSlices->Array.map((module(V: StateViewSlice.T)) =>
    (V.Spec.name, V.Spec.consumedEventSchema->S.castToUnknown)
  )
)
switch Reventless.DcbValidation.validateProducedAndConsumed(~produced, ~consumed) {
| Error(errors) => errors->Array.forEach(err =>
    Console.error(`DCB validation error (${err.sliceName}): ${err.message}`)
  )
| Ok() => ()
}

// 2-4. Create shared resources
let partitionTag = Reventless.DcbTag.derivePartitionTag(producedSchemas)
module DcbEventLog = DcbEventLog_Builder.Make(DcbEventLogStorage, DcbEventTopicPublisher)
let dcbEventLog = DcbEventLog.make(~name, ~indexes, ~partitionTag, ~opts)

// 5. Sync CommandTopic (standard SQS) — always created
module DcbCommandTopic = CommandTopic_Builder.Make(DcbCommandTopicSpec, DcbCommandTopicChannel)
let dcbCommandTopic = DcbCommandTopic.make(~name=`${name}StateChanges`, ~opts)

let publishJsons =
  dcbCommandTopic->Component.operations->Pulumi.Output.apply(ops => ops.publishJsons)

// Partition stateChangeSlices by channel mode (MakeAsync sets isAsync = true)
let syncSlices = stateChangeSlices->Array.filter((module(M: StateChangeSlice.T)) => !M.isAsync)
let asyncSlices = stateChangeSlices->Array.filter((module(M: StateChangeSlice.T)) => M.isAsync)

// 6. Async CommandTopic (FIFO SQS) — only created if any MakeAsync slices present
module DcbCommandTopicSpecAsync = { let name = childName ++ "Async"; @schema type command = JSON.t }
module DcbAsyncCommandTopic = CommandTopic_Builder.Make(DcbCommandTopicSpecAsync, DcbCommandTopicChannelAsync)
let asyncDcbCommandTopicOpt = if asyncSlices->Array.length > 0 {
  Some(DcbAsyncCommandTopic.make(~name=`${name}DcbAsync`, ~opts))
} else { None }

// 7. Each sync StateChangeSlice.make registers its handler in the global registry
syncSlices->Array.map((module(Slice: StateChangeSlice.T)) => {
  Slice.make(~dcbEventLog, ~publishJsons, ~opts)
})

// 8. Each async StateChangeSlice uses the FIFO CommandTopic's publishJsons
asyncDcbCommandTopicOpt->Option.forEach(asyncTopic => {
  let asyncPublishJsons = asyncTopic->Component.operations->Pulumi.Output.apply(ops => ops.publishJsons)
  asyncSlices->Array.map((module(Slice: StateChangeSlice.T)) => {
    Slice.make(~dcbEventLog, ~publishJsons=asyncPublishJsons, ~opts)
  })
})

// 9. Each StateViewSlice.make creates its own QueryDb and subscribes
stateViewSlices->Array.map((module(Slice: StateViewSlice.T)) => {
  Slice.make(~dcbEventLog, ~opts)
})

// 11-12. One Lambda per CommandTopic
let dcbHandler = DcbCommandTopic.makeFilteringHandler(dcbCommandTopic)
let dcbRuntimeSetup = () => {
  dcbCommandTopic->PluginRuntimeBuilder.forDcbCommandTopic(~handler=dcbHandler, ~connect=dcbConnectFn)
  asyncDcbCommandTopicOpt->Option.forEach(asyncTopic => {
    let asyncHandler = DcbAsyncCommandTopic.makeFilteringHandler(asyncTopic)
    asyncTopic->PluginRuntimeBuilder.forDcbCommandTopic(~handler=asyncHandler->Obj.magic, ~connect=asyncConnectFn)
  })
}
```

### Schema-Based Handler Registration

`StateChangeSlice_Builder.Make.construct` registers each slice's handler:

```rescript
dcbEventLog
->Component.operations
->Pulumi.Output.apply(dcbEventLogOps => {
  let jsonHandler = makeJsonHandler(dcbEventLogOps)  // decodes JSON → Spec.command, calls Callback
  CommandTopic.registerHandler(
    ~schema=commandSchema,   // S.t<unknown> cast from Spec.commandSchema
    ~handler=jsonHandler,
    ~typeNames=commandTypeNames,  // e.g. ["AddProduct"]
  )
})
```

`CommandTopic.registerHandler` populates `globalRegistry` — a module-level `Dict.t<array<handlerEntry>>` keyed by command type name (e.g. `"AddProduct"`, `"RenameCategory"`).

### Filtering Handler

`filteringHandler` is defined at module level in `CommandTopic_Builder.Make`. It is the actual Lambda callback:

```rescript
let filteringHandler: jsonCommandsHandler = async jsonItems => {
  let allResults = []
  jsonItems->Array.map(async ({reference, command: json}) => {
    let typeName = extractTypeNameFromJson(json)  // reads json["TAG"]
    let handlers = CommandTopic.getHandlers(typeName)  // reads globalRegistry
    handlers->Array.map(async ({handler}) => {
      let results = await handler([{reference, command: json}])
      allResults->Array.pushMany(results)
    })
  })
  allResults
}
```

`CommandTopic.extractTypeNamesFromSchema` reads the sury schema to extract variant names from the `TAG` const fields — supporting both single-variant (`Object`) and multi-variant (`Union`) command types.

### `StateChangeSlice_Callback`: Decision Logic

`StateChangeSlice_Callback.Make(Spec)` produces a module whose `handleCommands` takes `dcbEventLog` as an explicit runtime parameter (rather than capturing it via a functor argument). This allows `Callback` to be created at module level in `StateChangeSlice_Builder.Make`, where the type system can properly unify `Callback.Spec.command` with the outer `Spec.command`.

The callback uses per-slice encoding/decoding:
- **Decode**: `DcbDecode.makeDecoder(Spec.consumedEventSchema)` — decodes raw stored events by TAG, handling payload-less, partial, and full shapes
- **Encode**: `S.reverseConvertToJsonOrThrow(Spec.eventSchema)` + `DcbTag.extractTags` — encodes produced events to raw storage format with tags

`handleCommands(dcbEventLog, stream)` processes each command:

1. Builds the query automatically using `DcbTag.buildQueryFromCommand(~eventTypes=queryEventTypes, ~schema=Spec.commandSchema, ~value=command)` where `queryEventTypes` is derived at module init from `DcbDecode.makeDecoder(Spec.consumedEventSchema).eventTypes`. The query mode is determined by schema introspection:
   - **Scalar tags only** (e.g., `productId: @s.matches(DcbTag.string) string`) → single AND clause (standard single-entity query)
   - **Tagged array fields** (e.g., `productIds: array<@s.matches(DcbTag.stringForKey(~key="productId")) string>`) → per-element OR clauses (cross-entity query for commands referencing multiple entities). The PPX accepts both spellings: `productId: array<string>` (singular field name, tag key inferred from the field) and `productIds: array<string>` (plural field name, trailing `s` stripped → tag key `productId`); both store under the same tag key so plural and singular producers/consumers interoperate.
2. Streams events from the event log: `dcbEventLog.readStream(~query)`
3. Decodes each raw event using `decoder.decode(~eventType, ~data)`, skipping unrecognised events
4. Folds decoded events into the decision state: `Stream.runFold` with `Spec.evolve` starting from `Spec.initialState`
5. Calls `Spec.decide(state, command)` to produce new events or an error
6. Encodes produced events via `encodeProducedEvent` and appends with optimistic concurrency: `dcbEventLog.append(rawEvents, ~condition={query, after: headPosition})`
7. Retries up to 3 times on append conflict (position changed between read and write)

### `StateViewSlice_Callback`: Projection Logic

`StateViewSlice_Callback.Make(Spec)` produces a module that handles events from the DcbEventLog and projects them into a QueryDb-backed read model.

`eventsHandler(queryDbOps, events)` processes each event:

1. For each event, calls `Spec.project(event)` to generate projection actions
2. Uses `Projection.handleActions` to apply the actions to QueryDb (Set, Delete, Update, etc.)

Unlike StateChangeSlice which handles commands and decides on events, StateViewSlice simply projects events into its read model.

### `Plugin_Builder.Make` Functor Parameters

The functor requires four DCB-specific adapters alongside the standard ones:

```rescript
module Make = (
  Spec: Spec,
  ApiSpec: { type api; type role },
  FragmentProvider: Api_Adapter.Provider,
  RuntimeEnvironment: Runtime.Environment,
  EventCollectorChannel: EventCollector_Adapter.Channel ...,
  QueryEngineAdapter: QueryDb_Adapter.QueryEngineAdapter,
  PluginExtensionPointRemoteChannel: CommandTopic_Adapter.RemoteChannel,
  HeartbeatRunner: Heartbeat_Adapter.Runner ...,
  PluginRuntimeBuilder: PluginRuntime_Builder.T ...,
  DcbEventLogStorage: DcbEventLog_Adapter.Storage,            // e.g. DynamoDB adapter
  DcbEventTopicPublisher: EventTopic_Adapter.Publisher,       // e.g. DynamoDB Stream → SNS
  DcbCommandTopicChannel: CommandTopic_Adapter.Channel,       // sync (standard SQS)
  DcbCommandTopicChannelAsync: CommandTopic_Adapter.Channel,  // async (FIFO SQS)
): Plugin.T with type api = ApiSpec.api and type role = ApiSpec.role
```

All four DCB adapters are always required as functor parameters even if a specific plugin instance doesn't use DCB (all slice arrays default to `[]` at the `make` call site, so no queues are provisioned). Platforms that never use async slices can safely pass the same channel module for both `DcbCommandTopicChannel` and `DcbCommandTopicChannelAsync`.

## Build-Time Validation

`DcbValidation.validateProducedAndConsumed` enforces four rules at build time:

1. **Payload equivalence**: If multiple slices produce the same TAG (e.g., two slices both produce `| ProductAdded({...})`), their payloads must be structurally identical
2. **Producer coverage**: Every consumed event TAG must have at least one producer across all StateChangeSlices
3. **Field subset**: Consumed event fields must exist in the produced event shape (consumers can consume a subset)
4. **Type compatibility**: Consumed field types must be compatible with produced field types

This build-time, schema-level validation is what allows the decoupled event types described below: each slice declares its own `consumedEvent` / `event` rather than sharing a single compile-time `dcbEvent` union.

## Design Decisions

### Decoupled Event Types (No Shared Union)

Each slice declares its own `consumedEvent` and `event` types. This is the key architectural decision behind the current design:

- **Producers** declare the full event payload they write (e.g., `| ProductAdded({productId, name, description, price})`)
- **Consumers** declare only what they need to read — this can be:
  - **Payload-less**: `| ProductAdded` — just needs to know the event happened
  - **Partial**: `| ProductAdded({productId})` — only needs some fields
  - **Full**: `| ProductAdded({productId, name, description, price})` — needs everything

The framework validates compatibility via `DcbValidation` and handles decoding via `DcbDecode`, which matches by TAG name and parses the available fields.

### Global Registry

`CommandTopic.globalRegistry` is a module-level mutable `Dict.t<array<handlerEntry>>`. State change slices populate it inside `Pulumi.Output.apply` callbacks during deploy time.

When Pulumi creates the DCB command topic Lambda using `aws.lambda.CallbackFunction`, it serializes the `filteringHandler` closure and its entire module graph, including the populated `globalRegistry`. The serialized Lambda bundle therefore contains the registered handlers with all their captured state (DcbEventLog DynamoDB table ARN etc.).

**Limitation**: all `registerHandler` calls must resolve (i.e., their `Pulumi.Output.apply` callbacks must run) before Pulumi serializes the Lambda. This is expected to happen in practice since all outputs in the plugin resolve during the same `pulumi up` execution, but there is no explicit ordering guarantee in the current implementation.

### No `Obj.magic`

The DCB implementation contains no unsafe type casts. Two problems that originally required `Obj.magic` were resolved structurally:

**1. `Callback.Spec.command` unification in `StateChangeSlice_Builder`**

When `Callback = StateChangeSlice_Callback.Make(Spec, Ops)` was created inside `makeJsonHandler` (a function), the type checker treated `Callback.Spec.command` as a fresh nominal type distinct from the outer `Spec.command`, even though they are identical at runtime.

Fix: `StateChangeSlice_Callback.Make` now takes only `Spec` as a functor parameter. The `dcbEventLog` operations are passed as a regular runtime argument to `handleCommands`. `Callback` is therefore created at module level in `StateChangeSlice_Builder.Make`, where the type system correctly unifies `Callback.Spec.command` with `Spec.command`:

```rescript
module Callback = StateChangeSlice_Callback.Make(Spec)  // module level — types unify

let makeJsonHandler = (dcbEventLogOps) => {
  let handler: CommandTopic.jsonCommandsHandler = stream => {
    let decodedStream = stream->Stream.mapEffect(...)
    Callback.handleCommands(dcbEventLogOps, decodedStream)  // no cast needed
  }
  handler
}
```

**2. Type mismatch between `DcbCommandTopic.operations` and `StateChangeSlice.operations` in `Plugin_Builder`**

`DcbCommandTopic.operations = {publish, publishJsons}` did not match `StateChangeSlice.T.make`'s expected `CommandTopic.component<{publishJsons}>`, even though only `publishJsons` is used by slices.

Fix: `StateChangeSlice.T.make` now accepts `~publishJsons: Pulumi.Output.t<CommandTopic.publishJsons>` directly instead of the whole command topic component. `Plugin_Builder` extracts `publishJsons` before the slice loop:

```rescript
let publishJsons =
  dcbCommandTopic->Component.operations->Pulumi.Output.apply(ops => ops.publishJsons)
Slice.make(~dcbEventLog, ~publishJsons, ~opts)
```

**3. `DcbCommandTopic.component` type escaping the `switch` arm in `Plugin_Builder`**

`DcbCommandTopic` is a locally-defined module inside a `switch` arm. Storing the component value in the return tuple caused its local type to escape the arm's scope.

Fix: the `forDcbCommandTopic` call is wrapped in a `unit => unit` closure while `DcbCommandTopic` is still in scope. The closure is stored in the tuple instead of the component:

```rescript
let dcbRuntimeSetup = () =>
  dcbCommandTopic->PluginRuntimeBuilder.forDcbCommandTopic(~handler=dcbHandler, ~connect=dcbConnectFn)

// stored as: Some(dcbRuntimeSetup)
// used later as: dcbRuntimeOpt->Option.forEach(setup => setup())
```

## Event Log Partitioning

The DCB EventLog uses **primary-tag partitioning** — each event's tag determines its DynamoDB partition key. Instead of a single `id="dcb"` partition for all events, the partition key is `"<tagKey>:<tagValue>"` (e.g., `"productId:prod-1"`, `"categoryId:cat-1"`).

This distributes events across DynamoDB partitions by entity, eliminating the single-partition bottleneck and enabling per-entity queries via direct key lookups instead of secondary index queries.

### How partitioning works

**Write path**: Each event's first tag determines its partition key. A `ProductAdded({productId: "p1", ...})` event goes to partition `productId:p1`. A `CategoryAdded({categoryId: "c1", ...})` event goes to partition `categoryId:c1`.

**Read path**: Each query clause routes to the partition matching its tag. A query for `{tags: [{key: "productId", value: "p1"}]}` does a direct partition key lookup on `productId:p1` — no secondary index needed.

**Multi-clause queries**: Cross-entity queries (e.g., PlaceOrder referencing multiple products) dispatch each clause to its target partition in parallel, then merge results using the existing k-way merge.

### Partition tag derivation

At build time, `Dcb_Builder` calls `DcbTag.derivePartitionTag` on all produced event schemas. The rules are:

| Scenario | Behavior |
|----------|----------|
| **All events have one tag field each** (even if different names) | Auto-selected — each event uses its own tag. Multi-entity DCB logs work naturally. |
| **Any single event variant has multiple tag fields** | Requires explicit `@s.matches(DcbTag.partition)` annotation on one field. |
| **Only one tag field across all schemas** | Auto-selected — no annotation needed. |

### Marking the partition key

When a single event variant has multiple tagged fields, one must be designated as the partition key. There are two ways:

**`@partitionTag` field annotation (recommended in slice files):**

In files where `@@reventless.dcbTags` is active (including all `*Slice/` folders), use the `@partitionTag` field annotation — the PPX transforms it to `@s.matches(DcbTag.partition)`:

```rescript
// In a StateChangeSlice file
@schema
type event =
  | DemandRecorded({
      @partitionTag productId: string,  // partition key
      orderId: string,                  // regular DcbTag.string
    })
```

**`@s.matches(DcbTag.partition)` (explicit, for event log type definitions):**

In event log type files where dcbTags is not active, annotate directly:

```rescript
@schema
type event =
  | OrderPlaced({
      orderId: @s.matches(DcbTag.partition) string,
      customerId: @s.matches(DcbTag.string) string,
    })
```

Both fields remain DCB tags (used for query filtering), but the annotated field determines the partition key. Events without the designated partition tag fall back to their first tag.

For most DCB specs — where each event variant has exactly one tagged field — no annotation is needed. You only reach for `@partitionTag` when an event carries **two or more `*Id` fields** and the storage partition would otherwise be ambiguous — most often because the event also carries a **foreign reference** (see the next section).

### Cross-entity reference reads (inferred — no annotation)

The common cross-partition case — "this command references another entity; does it exist / is it valid?" — needs **no tag annotation at all**. You declare the fields and what the slice consumes, and the framework derives the scope from the whole plugin's slice graph:

```rescript
// AddProduct.res — references a Category. Zero scope annotations.
@schema
type consumedEvent =
  | ProductAdded({productId: string})        // my own lifecycle
  | CategoryAdded({categoryId: string})      // the category's lifecycle…
  | CategoryArchived({categoryId: string})
@schema
type command = AddProduct({@partitionTag productId: string, name, price, categoryId: string})
@schema
type event   = ProductAdded({@partitionTag productId: string, name, price, categoryId: string})
```

Because `categoryId` is owned by another entity (Category emits `CategoryAdded` keyed by it), the framework infers that `AddProduct` reads it **cross-partition** — the `categoryId` clause reads only the category's lifecycle, never sibling products — and that `categoryId` is **payload** on the emitted `ProductAdded` (so the event is never written to the `categoryId` index). You write no `@crossPartition` and no `@noTag`.

The one annotation still required here is **`@partitionTag productId`**: the emitted `ProductAdded` carries two `*Id` fields (`productId` + the foreign `categoryId`), so storage needs to be told which one is the partition. (Inferring the storage partition is planned; until then, mark it.)

If you write a redundant or contradictory `@crossPartition` the build logs a diagnostic — a key marked cross-partition that the framework resolves as the slice's *own* partition is flagged as a contradiction.

### Composite partition keys (`@compositePartitionTag`)

When the optimal partition key is formed from **multiple fields concatenated together in declaration order** (e.g. `environment/platform/plugin`), use `@compositePartitionTag` instead of `@partitionTag`:

```rescript
@@reventless.spec

@schema
type event =
  | PluginSynced({
      @compositePartitionTag environment: string,   // sep "/" after this field
      @compositePartitionTag platformName: string,  // sep "/" after this field
      @compositePartitionTag pluginName: string,    // last — sep ignored
      version: string,
    })
/// Partition key: field values joined in declaration order
// e.g.  "prod/acme-platform/billing"
```

Each `@compositePartitionTag` field is still a regular DCB tag — individually queryable via `tags: [{key: "environment", value: "prod"}]`. The composite key is only used for the DynamoDB partition; the runtime builds it from the stored tag values at append time.

**Separator control** — the separator after each field is configurable:

```rescript
@compositePartitionTag            // default: "/"
@compositePartitionTag("/")       // explicit default — same behaviour
@compositePartitionTag(":")       // use ":" between this and the next field
```

**Rules:**
- Requires ≥ 2 annotated fields — `derivePartitionTag` throws at startup if only 1 is found.
- Cannot mix `@compositePartitionTag` with `@partitionTag` on the same schema — throws at startup.
- Annotations must be on `string` fields; non-string fields are silently ignored.
- Placement is **before the field name** (field-level attribute), not after the colon.

### M:N capacity reads (`@crossPartition`) — the escape hatch inference can't see

The reference case above is inferred because the foreign key is *another entity's*
partition. The one case the framework **cannot** infer is the **M:N capacity
invariant**, where a slice reads its **own** event type by a secondary key across
*all* of that key's partitions — e.g. "≤ N subscriptions per student": the slice
both produces and reads `StudentSubscribed`, so inference sees `studentId` as an
own-stream read (partition-scoped), not a cross-partition one. Here you must opt in.

Because each event lives in exactly one partition (its partition tag), a
single-tag read of any *other* tag is **partition-scoped** by default — it keeps
that tag's consistency fence narrow. The M:N invariant needs the opposite: read
`studentId` across every course partition the student appears in.

Mark such a tag `@crossPartition` (on the command **and** the produced event,
like `@partitionTag` — never on `consumedEvent`):

```rescript
// Course-subscription capacity: partition by courseId, read studentId across
// every course partition the student appears in.
@schema
type command =
  | SubscribeStudent({
      @partitionTag courseId: string,      // partition read — "all of the course"
      @crossPartition studentId: string,   // cross-partition read — "all of the student"
    })

@schema
type event =
  | StudentSubscribed({
      @partitionTag courseId: string,
      @crossPartition studentId: string,
    })
```

`SubscribeStudent` now builds **two single-tag reads** (one per entity) instead
of one composite read of the exact `{course, student}` pair. Under the hood the
`studentId` read routes to the per-tag `tag_studentId` GSI (eventually
consistent — the append fence catches staleness), and `studentId`'s fence is
bumped by **every** `StudentSubscribed`, so a concurrent subscribe for the same
student conflicts at append. See the [PPX `@crossPartition` reference](reventless-ppx.md#crosspartition--cross-partition-secondary-tag-reads)
for the full read/fence semantics.

**Use it deliberately.** It is opt-in because a cross-partition tag's fence is
hotter (every writer of that tag contends on one fence) and the read scales with
the entity's degree. For threshold rules ("≤ N …") prefer a bounded count read
over folding the whole set. The scope is a property of the tag *key* and must
agree across every event type that carries it — `Dcb_Builder` reports a mismatch
at build time.

## Open Issues

### No Explicit Lambda Serialization Ordering

As noted above, there is no explicit Pulumi dependency ensuring that `globalRegistry` is fully populated before the DCB command topic Lambda is serialized. In practice this works because all outputs resolve synchronously within `pulumi up`, but it is fragile and could break if the execution order changes.

A more robust alternative would be to store handlers on the `DcbCommandTopic` component itself (e.g. via a JS property) rather than in a module-level global, so the populated state is always local to the component being serialized.

### No Multi-Command-Type Support in `extractTypeNamesFromSchema`

`CommandTopic.extractTypeNamesFromSchema` handles `Union` (multiple variants) and `Object` (single variant). It does not handle payload-less variants (string schemata) — these variants are silently ignored and would never be routed to a handler. Slices whose command type includes a payload-less variant (e.g. `| NoOp`) should be aware that `NoOp` commands will not be dispatched by the filtering handler (they will fall through with no result). See the `MEMORY.md` note on payload-less variants.

### Aggregates Intentionally Use `makeHandler`

Aggregates still create their own `CommandTopic` per aggregate with their own Lambda. Although the schema-based `registerHandler` API was added to `CommandTopic.T`, `Aggregate_Builder` intentionally continues to use `makeHandler` with a strongly-typed `commandsHandler`. This is a deliberate architectural choice, not an oversight:

1. **Type safety**: `makeHandler` accepts a `commandsHandler<Message.command'<Spec.Id.t, Spec.command>>` — the command type is fully resolved at compile time. No JSON decode step is needed at the handler boundary; the framework can pass a typed value directly. `registerHandler` (used by DCB slices) takes a `jsonCommandsHandler` and must decode each command from JSON at runtime, which adds a failure surface.

2. **Isolation**: Each aggregate gets its own SQS FIFO queue and its own Lambda. A crash or overload in one aggregate's Lambda cannot affect another aggregate's command processing. DCB slices intentionally share one Lambda (because they share one `DcbEventLog`), so `registerHandler` with a global dispatch table is needed there. Aggregates have no such sharing requirement.

3. **Simplicity**: `registerHandler` depends on a global `Dict` that must be populated before the Lambda serialization completes. A single functor application in the wrong place can silently leave a handler unregistered. `makeHandler` has no global state — it returns a handler directly from the builder, making the wiring explicit and easy to reason about.

4. **Architecture fit**: Each aggregate owns a separate event log and a separate command topic. There is no shared resource that would justify collapsing multiple aggregates into a single Lambda. The cost (complexity, global registry risk) would outweigh any benefit.

In short: DCB slices use `registerHandler` because they *must* share a Lambda to share a `DcbEventLog`. Aggregates use `makeHandler` because they *can* have dedicated Lambdas, and the simpler, type-safe path is strictly better for them.
