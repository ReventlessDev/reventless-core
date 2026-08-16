---
title: DCB Usage
---

# DCB Usage

The Plugin component supports an optional DCB (Dynamic Consistency Boundary) event log shared across multiple slices. All slices in a plugin read from and write to the same event log, with optimistic concurrency control enforced per command.

Each slice declares its own `consumedEvent` and `event` types independently — there is no shared event union. The framework validates compatibility between producers and consumers at build time via `DcbValidation`.

## Command Flow

```
Client → AppSync mutation → DCB command handler → filteringHandler
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

All of a plugin's StateChangeSlices share one command-handler Lambda, and the
`filteringHandler` inside it routes each command by its `TAG` field to whichever
slices handle that command type. Slices that don't handle a command type are
never called.

Which Lambda a command lands in depends on the slice's dispatch mode. By default
a slice is **synchronous**: the mutation reaches the plugin's `DcbCmdHandler`
directly and returns `CommandAccepted` or `CommandRejected` to the caller. A
slice that opts in with `@@reventless.async` is routed instead through a FIFO
queue to the plugin's `DcbAsyncCmdHandler`, and the mutation returns
`CommandPending` immediately. The async Lambda and its queue are only provisioned
when at least one slice opts in.

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

  let project: Reventless.StateViewSlice.consumed<consumedEvent> => array<Projection.action<string, state>>
}
```

Note: `project` receives a `consumed` envelope `{event, meta, recordedAt}` (not `option<state>`); destructure `({event})` when you only need the payload. `meta.time` (producer timestamp) and `recordedAt` (storage timestamp) are available. Use `Update(id, fn)` for state-dependent projections.

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

A view slice is two files in a `StateViewSliceStream/` folder. The spec file declares `consumedEvent` and the read model `state`:

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

The projection file (`@@reventless.projection`) declares `project`, which receives a `consumed` envelope `{event, meta, recordedAt}` (destructure `({event})` when you only need the payload); `Set`/`Update`/`Delete` are in scope without a prefix:

```rescript
// Categories_Projection.res
@@reventless.projection

let project = ({event}) =>
  switch event {
  | CategoryAdded({categoryId, name}) => [Set(categoryId, {categoryId, name, archived: false})]
  | CategoryRenamed({categoryId, name}) => [Update(categoryId, state => {...state, name})]
  | CategoryArchived({categoryId}) => [Update(categoryId, state => {...state, archived: true})]
  }
```

### 3. Wire slices via the Platform

`src/Plugin.res` is **auto-generated** by `generate-plugin` (from `reventless-spec`) before each build — no hand-authored composition root needed. The generator discovers all slice specs from their parent folder names and pairs each spec with its body file via a two-argument functor call:

```rescript
// AUTO-GENERATED — do not edit. Run `pnpm run generate` to update.
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

## Build-Time Validation

`DcbValidation.validateProducedAndConsumed` enforces four rules at build time:

1. **Payload equivalence**: If multiple slices produce the same TAG (e.g., two slices both produce `| ProductAdded({...})`), their payloads must be structurally identical
2. **Producer coverage**: Every consumed event TAG must have at least one producer across all StateChangeSlices
3. **Field subset**: Consumed event fields must exist in the produced event shape (consumers can consume a subset)
4. **Type compatibility**: Consumed field types must be compatible with produced field types

This build-time, schema-level validation is what allows the decoupled event types described below: each slice declares its own `consumedEvent` / `event` rather than sharing a single compile-time `dcbEvent` union.

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

## Under the hood

How the shared log, the command topic, the filtering handler, and the per-slice
registration are actually built at deploy time — and why they are built that
way — is framework-side detail. See
[DCB in the framework](/framework/architecture/dcb) for the wiring, the design
decisions behind it, and the known rough edges, and
[DCB consistency checks](/framework/internals/dcb-consistency-checks) for how a
decision's read condition becomes the fences enforced on append.
