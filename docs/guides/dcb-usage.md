# DCB Plugin Support

The Plugin component supports an optional DCB (Dynamic Consistency Boundary) event log shared across multiple slices. All slices in a plugin read from and write to the same event log, with optimistic concurrency control enforced per command.

Each slice declares its own `consumedEvent` and `producedEvent` types independently — there is no shared event union. The framework validates compatibility between producers and consumers at build time via `DcbValidation`.

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

### `StateChangeSlice.Spec`

Each slice independently declares its `consumedEvent` (what it reads) and `producedEvent` (what it writes). These need not be the same type — a slice can consume a payload-less variant (e.g., `| ProductAdded`) and produce a full variant (e.g., `| ProductAdded({productId, name, ...})`).

```rescript
module type Spec = {
  let name: string
  let moduleUrl: string

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
  type producedEvent

  let decide: (state, command) => result<array<producedEvent>, error>
}
```

The `@schema` annotation auto-generates sury schemas: `consumedEventSchema`, `commandSchema`, `errorSchema`, `producedEventSchema`.

### `StateViewSlice.Spec`

```rescript
module type Spec = {
  let name: string
  let moduleUrl: string

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
  let name: string
  let moduleUrl: string

  @schema
  type consumedEvent

  @schema
  type todoItem

  @schema
  type command

  let collect: consumedEvent => array<(string, todoItem)>
  let resolve: consumedEvent => option<string>
  let process: (string, todoItem) => option<(string, command)>
  let maxRetries: int
  let heartbeatInterval: int
}
```

### `OutboundTranslationSlice.Spec`

Translates internal events to external side-effects, producing commands that feed back into the DCB.

```rescript
module type Spec = {
  let name: string
  let moduleUrl: string

  @schema
  type consumedEvent

  @schema
  type outboundItem

  @schema
  type inboundCommand

  let collect: consumedEvent => array<(string, outboundItem)>
  let translate: (string, outboundItem) => promise<result<option<(string, inboundCommand)>, string>>
  let maxRetries: int
  let heartbeatInterval: int
}
```

### `InboundTranslationSlice.Spec`

Translates external inputs into DCB commands.

```rescript
module type Spec = {
  let name: string
  let moduleUrl: string

  @schema
  type externalInput

  @schema
  type command

  let translate: externalInput => result<(string, command), string>
}
```

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

Each spec is a standalone module with its own `consumedEvent` and `producedEvent` types. No shared event log spec module is needed.

```rescript
// AddProduct.res
open Reventless

let name = "AddProduct"
let moduleUrl: string = %raw(`import.meta.url`)

type state = {exists: bool}
let initialState = {exists: false}

@schema
type consumedEvent = ProductAdded

let evolve = (_state, event) =>
  switch event {
  | ProductAdded => {exists: true}
  }

@schema
type command =
  | AddProduct({
      productId: @s.matches(DcbTag.string) string,
      name: string,
      description: string,
      price: float,
    })

@schema
type error = ProductAlreadyExists

@schema
type producedEvent =
  | ProductAdded({
      productId: @s.matches(DcbTag.string) string,
      name: string,
      description: string,
      price: float,
    })

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

Note: `consumedEvent` is a payload-less `| ProductAdded` — it only needs the TAG to know the event happened. `producedEvent` carries the full payload. The framework validates at build time that every `consumedEvent` TAG has a matching producer.

Fields marked `@s.matches(DcbTag.string)` become DCB tags — the event log is queried by these values to build the decision model. Each event's first tag is also used as the DynamoDB partition key (see [Event Log Partitioning](#event-log-partitioning) below).

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
// Internal refund processing — triggered by automation, not exposed to API
@schema @noApi
type command = IssueRefund({orderId: string, reason: string})
```

The `@noApi` annotation prevents commands from appearing in:
- GraphQL mutations
- MCP tool definitions
- API documentation

The command still executes normally when called programmatically or by internal automations.

### 2. Define state view slice specs

```rescript
// CategoriesView.res
open Reventless.Projection

let name = "CategoriesView"
let moduleUrl: string = %raw(`import.meta.url`)

@schema
type state = {categoryId: string, name: string, archived: bool}

@schema
type consumedEvent =
  | CategoryAdded({categoryId: string, name: string})
  | CategoryRenamed({categoryId: string, name: string})
  | CategoryArchived({categoryId: string})

let project = event =>
  switch event {
  | CategoryAdded({categoryId, name}) => [
      Set(categoryId, {categoryId, name, archived: false}),
    ]
  | CategoryRenamed({categoryId, name}) => [Update(categoryId, state => {...state, name})]
  | CategoryArchived({categoryId}) => [Update(categoryId, state => {...state, archived: true})]
  }
```

### 3. Build slices via the Platform

Slices are built through the platform's builder functors. The shared CommandTopic and DcbEventLog are injected by the plugin at deploy time.

```rescript
module CatalogPlugin = {
  module Make = (Platform: ReventlessInfra.Platform.T) => {
    module AddProductSlice = Platform.StateChangeSlice.Make(AddProduct)
    module ChangeProductNameSlice = Platform.StateChangeSlice.Make(ChangeProductName)
    module AddCategorySlice = Platform.StateChangeSlice.Make(AddCategory)
    module RenameCategorySlice = Platform.StateChangeSlice.Make(RenameCategory)
    module ArchiveCategorySlice = Platform.StateChangeSlice.Make(ArchiveCategory)

    module ProductsViewSlice = Platform.StateViewSlice.Make(ProductsView)
    module CategoriesViewSlice = Platform.StateViewSlice.Make(CategoriesView)

    module ImportProductSlice = Platform.InboundTranslationSlice.Make(ImportProduct)

    // ...
  }
}
```

### 4. Create the plugin

Pass slice arrays directly to `Plugin.make`. Empty arrays can be omitted.

```rescript
let make = () =>
  Platform.Plugin.make(
    ~name="Catalog",
    ~heartbeatInterval=60,
    ~stateChangeSlices=[
      module(AddProductSlice),
      module(ChangeProductNameSlice),
      module(AddCategorySlice),
      module(RenameCategorySlice),
      module(ArchiveCategorySlice),
    ],
    ~stateViewSlices=[
      module(ProductsViewSlice),
      module(CategoriesViewSlice),
    ],
    ~inboundTranslationSlices=[module(ImportProductSlice)],
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
3. **Derives the partition tag** via `DcbTag.derivePartitionTag` — auto-selects when unambiguous, requires `DcbTag.partition` annotation when a variant has multiple tags
4. **Creates one `DcbEventLog`** using the plugin name, extracted indexes, and partition tag
4. **Creates one `DcbCommandTopic`** — typed as `command = JSON.t` (accepts all JSON)
5. **Constructs each `StateChangeSlice`** — passes shared resources; each slice registers its JSON handler in the global registry
6. **Constructs each `StateViewSlice`** — each slice gets its own QueryDb and subscribes to DcbEventLog events
7. **Constructs AutomationSlices, OutboundTranslationSlices, InboundTranslationSlices**
8. **Calls `DcbCommandTopic.makeFilteringHandler`** — wires `filteringHandler` to the SQS channel
9. **Creates the Lambda** and connects it to SQS

```rescript
// Inside Dcb_Builder.Make.construct:

// 1. Validation
let produced = stateChangeSlices->Array.map(
  (module(Sc: StateChangeSlice.T)) =>
    (Sc.Spec.name, Sc.Spec.producedEventSchema->S.castToUnknown)
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
module DcbEventLogMaker = DcbEventLog_Builder.Make(DcbEventLogStorage, DcbEventTopicPublisher)
let dcbEventLog = DcbEventLogMaker.make(~name, ~indexes, ~partitionTag, ~opts)

module DcbCommandTopicMaker = CommandTopic_Builder.Make(DcbCommandTopicSpec, DcbCommandTopicChannel)
let dcbCommandTopic = DcbCommandTopicMaker.make(~name=`${childName}-dcb-command-topic`, ~opts)

let publishJsons =
  dcbCommandTopic->Component.operations->Pulumi.Output.apply(ops => ops.publishJsons)

// 5. Each StateChangeSlice.make registers its handler in the global registry
stateChangeSlices->Array.map((module(Slice: StateChangeSlice.T)) => {
  Slice.make(~dcbEventLog, ~publishJsons, ~opts)
})

// 6. Each StateViewSlice.make creates its own QueryDb and subscribes
stateViewSlices->Array.map((module(Slice: StateViewSlice.T)) => {
  Slice.make(~dcbEventLog, ~opts)
})

// 8. Capture handler before DcbCommandTopic escapes scope
let dcbHandler = DcbCommandTopicMaker.makeFilteringHandler(dcbCommandTopic)
let dcbRuntimeSetup = () =>
  dcbCommandTopic->PluginRuntimeBuilder.forDcbCommandTopic(~handler=dcbHandler, ~connect=dcbConnectFn)
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
- **Encode**: `S.reverseConvertToJsonOrThrow(Spec.producedEventSchema)` + `DcbTag.extractTags` — encodes produced events to raw storage format with tags

`handleCommands(dcbEventLog, stream)` processes each command:

1. Builds the query automatically using `DcbTag.buildQueryFromCommand(~eventTypes=queryEventTypes, ~schema=Spec.commandSchema, ~value=command)` where `queryEventTypes` is derived at module init from `DcbDecode.makeDecoder(Spec.consumedEventSchema).eventTypes`. The query mode is determined by schema introspection:
   - **Scalar tags only** (e.g., `productId: @s.matches(DcbTag.string) string`) → single AND clause (standard single-entity query)
   - **Tagged array fields** (e.g., `productId: array<@s.matches(DcbTag.string) string>`) → per-element OR clauses (cross-entity query for commands referencing multiple entities)
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

The functor requires three DCB-specific adapters alongside the standard ones:

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
  DcbEventLogStorage: DcbEventLog_Adapter.Storage,       // e.g. DynamoDB adapter
  DcbEventTopicPublisher: EventTopic_Adapter.Publisher,  // e.g. SNS adapter
  DcbCommandTopicChannel: CommandTopic_Adapter.Channel,  // e.g. SQS FIFO adapter
): Plugin.T with type api = ApiSpec.api and type role = ApiSpec.role
```

These are always required as functor parameters even if a specific plugin instance doesn't use DCB (all slice arrays default to `[]` at the `make` call site).

## Build-Time Validation

`DcbValidation.validateProducedAndConsumed` enforces four rules at build time:

1. **Payload equivalence**: If multiple slices produce the same TAG (e.g., two slices both produce `| ProductAdded({...})`), their payloads must be structurally identical
2. **Producer coverage**: Every consumed event TAG must have at least one producer across all StateChangeSlices
3. **Field subset**: Consumed event fields must exist in the produced event shape (consumers can consume a subset)
4. **Type compatibility**: Consumed field types must be compatible with produced field types

This replaces the compile-time `with type dcbEvent = event` constraint from the previous shared-union approach with a more flexible schema-level validation.

## Design Decisions

### Decoupled Event Types (No Shared Union)

Each slice declares its own `consumedEvent` and `producedEvent` types. This is the key architectural decision behind the current design:

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

For most DCB specs — where each event variant has exactly one tagged field — no annotation is needed.

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
