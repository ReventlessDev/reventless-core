# DCB (Dynamic Consistency Boundary)

:::note Writing an application?
This page is the **framework-side** view: how DCB slices are wired at deploy
time and why the wiring looks the way it does. If you are building an
application, start at [What is a Dynamic Consistency
Boundary?](/app/concepts/dcb) and [DCB slices](/app/dcb-slices) instead.
:::

A plugin may carry a DCB event log shared across its state change slices. Every
slice in the plugin reads from and writes to that one log, and optimistic
concurrency is enforced per command rather than per entity — which is what lets
one command's decision read another entity's events.

## Command Flow

```d2
Client: Client { class: client }
SQS: "DCB Command Topic" { class: command-topic }
Handler: "filteringHandler" { class: command-generator }
Slice1: AddProduct Slice { class: state-change-slice }
Slice2: ChangeProductPrice Slice { class: state-change-slice }
EventLog: "DcbEventLog\n(Shared Event Log)" { class: dcb-event-log }
ViewSlice: "ProductsView Slice\n(Projection)" { class: state-view-slice }
QueryDb: "ProductsView\nQueryDb" { class: query-db }

Client -> SQS: { class: command-flow }
SQS -> Handler: { class: command-flow }
Handler -> Slice1: { class: command-flow }
Handler -> Slice2: { class: command-flow }
Slice1 -> EventLog: { class: event-flow }
Slice2 -> EventLog: { class: event-flow }
EventLog -> ViewSlice: { class: projection-flow }
ViewSlice -> QueryDb: { class: projection-flow }
```

All of a plugin's state change slices share one command-handler Lambda; the
`filteringHandler` inside it routes each command by its `TAG` field to the
slices that handle that command type, and never calls the others. A synchronous
slice — the default — is dispatched inline and answers the caller with
accepted or rejected. A slice marked `@@reventless.async` is routed through a
FIFO queue to a second handler and answers `CommandPending`; that queue and
handler exist only when at least one slice opts in.

## Module types

A DCB slice is two module types, deliberately split.

**`StateChangeSlice.Spec`** — the structural contract: `name`, an `Id` module,
and four schema-carrying types. `consumedEvent` names the events the slice reads
to build its decision state (payload-less where only existence matters);
`command`, `error`, and `event` describe what it accepts, refuses, and emits. It
also carries `commandSchema` (the DCB tags for the conditional read are extracted
from it), `commandAuthorization`, and `readConsistency` — all three injected by
`@@reventless.spec` with defaults, so a spec file states only its types.

**`StateChangeSlice.Behavior`** — the pure state machine over that spec:

```rescript
module type Behavior = {
  module Spec: Spec
  type state
  let initialState: state
  let evolve: (state, Spec.consumedEvent) => state
  let decide: (state, Spec.command) => result<array<Spec.event>, Spec.error>
  let moduleUrl: string
}
```

`state` is ephemeral — rebuilt by replaying the relevant events on every command,
never persisted. `evolve` and `decide` must be pure; everything that makes them
reachable is somebody else's job.

`StateViewSlice` mirrors the split for the read side, with a `project` function
in place of `decide`.

The split exists so the types can be shared without the state machine: the
generated composition root, the GraphQL schema, and the tag extraction all need
`Spec` alone, and only the command handler needs `Behavior`.

## Wiring

The plugin generator writes the composition root, so a slice is registered by
existing on disk:

```rescript
module AddCategorySlice = Platform.StateChangeSlice.Make(AddCategory, AddCategory_Behavior)

let make = () =>
  Platform.Plugin.make(
    ~name="Catalog",
    ~stateChangeSlices=[module(AddCategorySlice), /* … */],
    ~stateViewSlices=[module(CategoriesStreamSlice), /* … */],
  )
```

The shared event log is implicit: `Plugin.make` provisions one when the plugin
has any DCB slice, and its event schema is the union of what those slices emit.
There is no separate log spec to declare and keep in step.

## Plugin Outputs

```rescript
type outputs = {
  // ...existing outputs...
  dcbEventLog: Pulumi.Output.t<option<DcbEventLog.outputs>>,
  stateChangeSlices: Pulumi.Output.t<dict<StateChangeSlice.outputs>>,
  stateViewSlices: Pulumi.Output.t<dict<StateViewSlice.outputs>>,
}
```

- `dcbEventLog`: `Some(outputs)` when any DCB slice array is non-empty, `None` otherwise
- `stateChangeSlices`: keyed by `Spec.name`, contains resources for each slice
- `stateViewSlices`: keyed by `Spec.name`, contains QueryDb outputs for each slice

## Architecture

### Deploy-time setup

`Dcb_Builder` owns the DCB half of plugin construction. Given the plugin's
slices it:

1. **Derives the shared event-log schema** — one flat union over every event the
   plugin's state change slices emit. Flat, not nested: every reader of a log
   entry walks exactly one level, and a slice's events are identified by their
   variant tag. There is no separate log spec to declare, and no way for two
   slices to disagree about the log's type.
2. **Creates one `DcbEventLog`** for the plugin, named after it.
3. **Creates one command topic** typed as raw JSON, because it carries every
   slice's commands and the routing happens inside the handler.
4. **Constructs each state change slice**, handing it the shared log and the
   publish operation, and registering its handler under the command tags its
   `commandSchema` declares.
5. **Constructs each state view slice**, giving each its own QueryDb and an
   event collector subscribed to the shared log.
6. **Wires the filtering handler** to the channel and builds the command-handler
   Lambda around it.

The read-scope inference runs here too: a slice that reads another entity's
events by that entity's id gets a cross-partition read scope derived from the
plugin's slice graph, and the matching write tags on the events it emits. That
is why the common cross-entity reference case needs no annotation in the spec.

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
    ~typeNames=commandTypeNames,  // e.g. ["CreateItem"]
  )
})
```

`CommandTopic.registerHandler` populates `globalRegistry` — a module-level `Dict.t<array<handlerEntry>>` keyed by command type name (e.g. `"CreateItem"`, `"RenameItem"`).

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

`handleCommands(dcbEventLog, topicItems)` processes each command:

1. Builds the query automatically using `DcbTag.buildQueryFromCommand(~eventTypes=queryEventTypes, ~schema=Spec.commandSchema, ~value=command)` where `queryEventTypes` is derived at module init from `DcbTag.extractEventTypes(Spec.DcbEventLogSpec.eventSchema)`. The query mode is determined by schema introspection:
   - **Scalar tags only** (e.g., `itemId: @s.matches(DcbTag.string) string`) → single AND clause (standard single-entity query)
   - **Tagged array fields** (e.g., `productId: array<@s.matches(DcbTag.string) string>`) → per-element OR clauses (cross-entity query for commands referencing multiple entities)
2. Queries the event log: `dcbEventLog.readStream(~query)`
3. Folds those events into the decision state with `Behavior.evolve`, starting
   from `Behavior.initialState`
4. Calls `Behavior.decide(state, command)` to produce new events or an error
5. Appends with optimistic concurrency: `dcbEventLog.append(newEvents, ~condition={query, after: headPosition})`
6. Retries up to 3 times on append conflict (position changed between read and write)

For an end-to-end walkthrough of how the query is built from a command and how that condition becomes the per-tag consistency fences enforced atomically on DynamoDB — with worked `AddProduct` / `PlaceOrder` / `RecordProductDemand` examples — see [DCB Consistency Checks](../internals/dcb-consistency-checks.md).

### `StateViewSlice_Callback`: Projection Logic

`StateViewSlice_Callback.Make(Spec)` produces a module whose `handleEvents` function processes events from the DcbEventLog and projects them into the QueryDb read model.

`handleEvents(dcbEventLog, queryDb, topicItems)` processes each event:

1. Decodes each JSON event using `Spec.eventSchema`
2. Retrieves current state from QueryDb: `queryDb.get(~key=viewKey)`
3. Applies the projection function: `Spec.project(currentState, event)` which returns an array of projection actions
4. Uses `Reventless.Projection.Spec.handleActions` to process the actions and update state
5. Writes the updated state back to QueryDb: `queryDb.put(~key=viewKey, ~value=updatedState)`

The projection pattern allows StateViewSlice to maintain materialized views of the event log state, providing optimized read access to application data.

### `Plugin_Builder.Make` Functor Parameters

The functor requires three DCB-specific adapters alongside the standard ones:

```rescript
module Make = (
  Spec: Spec,
  RuntimeEnvironment: Runtime.Environment,
  EventCollectorChannel: EventCollector_Adapter.Channel ...,
  QueryEngineAdapter: QueryDb_Adapter.QueryEngineAdapter,
  CorePluginExtensionPointRemoteChannel: CommandTopic_Adapter.RemoteChannel,
  HeartbeatRunner: Heartbeat_Adapter.Runner ...,
  PluginRuntimeBuilder: PluginRuntime_Builder.T ...,
  DcbEventLogStorage: DcbEventLog_Adapter.Storage,       // e.g. DynamoDB adapter
  DcbEventTopicPublisher: EventTopic_Adapter.Publisher,  // e.g. SNS adapter
  DcbCommandTopicChannel: CommandTopic_Adapter.Channel,  // e.g. SQS FIFO adapter
): Plugin.T
```

These are always required as functor parameters even if a specific plugin instance doesn't use DCB (DCB slice arrays are optional at the `make` call site).

## Design Decisions

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
  let handler: CommandTopic.jsonCommandsHandler = async items => {
    let decodedItems = items->Array.filterMap(...)
    await Callback.handleCommands(dcbEventLogOps, decodedItems)  // no cast needed
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

### The shared log's type is derived, not declared

An earlier design had the plugin declare a DCB spec carrying the log's event
type, so the builder could instantiate the event log against it and constrain
every slice to the same type. That declaration is gone: the log's schema is
computed as the union of what the registered slices emit, which cannot drift
from the slices the way a hand-maintained declaration could. Each slice supplies
its own `commandSchema`, so nothing central needs to know the command type
either.

## Open Issues

### No Explicit Lambda Serialization Ordering

As noted above, there is no explicit Pulumi dependency ensuring that `globalRegistry` is fully populated before the DCB command topic Lambda is serialized. In practice this works because all outputs resolve synchronously within `pulumi up`, but it is fragile and could break if the execution order changes.

A more robust alternative would be to store handlers on the `DcbCommandTopic` component itself (e.g. via a JS property) rather than in a module-level global, so the populated state is always local to the component being serialized.

### Event Type Filtering Covers the Full Event Schema

`queryEventTypes` is derived automatically from `DcbEventLogSpec.eventSchema` via `DcbTag.extractEventTypes` at module initialisation time. This means a slice always queries all event types in the shared event log, not just those it handles in `reduce`. The `reduce` function's catch-all branch (`| _ => model`) discards irrelevant events correctly.

A future optimisation could narrow the query to only the event types referenced in `reduce`, but this would require compile-time introspection of the pattern match, which is not currently supported.

### No Multi-Command-Type Support in `extractTypeNamesFromSchema`

`CommandTopic.extractTypeNamesFromSchema` handles `Union` (multiple variants) and `Object` (single variant). It does not handle payload-less variants (string schemata) — these variants are silently ignored and would never be routed to a handler. Slices whose command type includes a payload-less variant (e.g. `| NoOp`) should be aware that `NoOp` commands will not be dispatched by the filtering handler (they will fall through with no result). 

### Aggregates Intentionally Use `makeHandler`

Aggregates still create their own `CommandTopic` per aggregate with their own Lambda. Although the schema-based `registerHandler` API was added to `CommandTopic.T`, `Aggregate_Builder` intentionally continues to use `makeHandler` with a strongly-typed `commandsHandler`. This is a deliberate architectural choice, not an oversight:

1. **Type safety**: `makeHandler` accepts a `commandsHandler<Message.command'<Spec.Id.t, Spec.command>>` — the command type is fully resolved at compile time. No JSON decode step is needed at the handler boundary; the framework can pass a typed value directly. `registerHandler` (used by DCB slices) takes a `jsonCommandsHandler` and must decode each command from JSON at runtime, which adds a failure surface.

2. **Isolation**: Each aggregate gets its own SQS FIFO queue and its own Lambda. A crash or overload in one aggregate's Lambda cannot affect another aggregate's command processing. DCB slices intentionally share one Lambda (because they share one `DcbEventLog`), so `registerHandler` with a global dispatch table is needed there. Aggregates have no such sharing requirement.

3. **Simplicity**: `registerHandler` depends on a global `Dict` that must be populated before the Lambda serialization completes. A single functor application in the wrong place can silently leave a handler unregistered. `makeHandler` has no global state — it returns a handler directly from the builder, making the wiring explicit and easy to reason about.

4. **Architecture fit**: Each aggregate owns a separate event log and a separate command topic. There is no shared resource that would justify collapsing multiple aggregates into a single Lambda. The cost (complexity, global registry risk) would outweigh any benefit.

In short: DCB slices use `registerHandler` because they *must* share a Lambda to share a `DcbEventLog`. Aggregates use `makeHandler` because they *can* have dedicated Lambdas, and the simpler, type-safe path is strictly better for them.
