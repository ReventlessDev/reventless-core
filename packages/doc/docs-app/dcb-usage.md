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

Each slice is a pair of files in a `StateChange/` folder. The spec file declares the slice's own `consumedEvent` (what it reads) and `event` (what it writes) — no shared event log spec module is needed. The PPX auto-injects `let name`, `module Id`, `let moduleUrl`, and applies `@s.matches(Reventless.DcbTag.string)` to every `*Id` field.

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

Auto-tagged `*Id` fields become DCB tags — the event log is queried by these values to rebuild state. One of them is the event's partition key, which decides where it is stored. The framework works that key out from what each slice writes and reads (see [Event Log Partitioning](#event-log-partitioning) below).

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
  | RecordDemand({productId: string, orderId: string})
  | RevokeDemand({productId: string, orderId: string})
```

The `@noApi` annotation prevents commands from appearing in:
- GraphQL mutations
- MCP tool definitions
- API documentation

The command still executes normally when called programmatically or by internal automations.

### 2. Define state view slice specs

A view slice is two files in a `StateViewStream/` folder. The spec file declares `consumedEvent` and the read model `state`:

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

The DCB EventLog uses **per-entity partitioning**. Every event is stored under one id, its **partition key**. Instead of a single `id="dcb"` partition for all events, the DynamoDB partition is `"<tagKey>:<tagValue>"` (e.g., `"productId:prod-1"`, `"categoryId:cat-1"`).

The partition key decides three things at once: where the event is stored, what a command reads before it decides, and which fence (the lock checked on append) guards the write. It is also the command's envelope id, which groups commands for the same entity on the FIFO queue.

This distributes events across DynamoDB partitions by entity, eliminating the single-partition bottleneck and enabling per-entity queries via direct key lookups instead of secondary index queries.

### How partitioning works

**Write path**: Each event type is stored under the partition key of the slice that writes it. `AddProduct` is partitioned by `productId`, so a `ProductAdded({productId: "p1", categoryId: "c1", ...})` event goes to partition `productId:p1`. `AddCategory` is partitioned by `categoryId`, so a `CategoryAdded({categoryId: "c1", ...})` event goes to partition `categoryId:c1`. The other `*Id` fields stay DCB tags you can query by; they just do not decide where the event lives.

**Read path**: Each query clause routes to the partition matching its tag. A query for `{tags: [{key: "productId", value: "p1"}]}` does a direct partition key lookup on `productId:p1` — no secondary index needed.

**Multi-clause queries**: Cross-entity queries (e.g., PlaceOrder referencing multiple products) dispatch each clause to its target partition in parallel, then merge results using the existing k-way merge.

Only the DynamoDB backend observes partitions. The local backends (in-memory and SQLite) keep one log and ignore them.

### How the partition key is inferred

You normally write no annotation. At build time the framework reads the whole plugin's slice graph — what each slice writes and what it reads — and works out one partition key per slice:

1. **Own ids.** Collect the `*Id` fields on the events the slice writes. If there is only one, that is the partition, whatever the slice reads.
2. **Minus references.** Remove every id that appears on a consumed arm whose event type *another* slice writes. `AddProduct` reads `CategoryAdded({categoryId})`, which `AddCategory` writes, so `categoryId` is a reference to another entity, not the product's own id.
3. **What is left.** Exactly one id left is the partition. Several left go to the chapter.
4. **The chapter breaks a tie.** A chapter is the folder above the kind folder (`src/Order/StateChange/PlaceOrder.res` is in the `Order` chapter). Of the ids left, the framework keeps those that *every* event written in the chapter carries. `PlaceOrder` is left with `orderId` and `customerId`: `customerId` refers to the customer, but nothing `PlaceOrder` reads shows that. Every event under `Order/` carries `orderId`, and only some carry `customerId`, so the partition is `orderId`. If that still leaves several ids — or the slice sits in no chapter — you add `@partitionTag` (see [below](#when-you-still-need-partitiontag)).

If step 2 removes *every* id, one more rule applies: an id is given back when every other-slice arm carrying it comes from a slice partitioned by that same id. Reading your own entity's events by its id is identity, not a reference — which is why `ChangeProductName` may read `ProductAdded({productId, name})`. This rule depends on other slices' partitions, so the framework repeats it across the plugin until nothing changes. Slices that read each other's events, such as `ShipOrder` and `CancelOrder`, resolve this way.

The same derivation drives storage, the fence, the command envelope id and the decision read, so they cannot disagree.

The chapter only breaks ties; it never overrides the steps before it. But where it does decide, the folder is part of the storage decision: moving such a slice into another chapter can change where its new events are stored, away from the ones already written. The golden `schema/dcb-scope.json` in the examples (`pnpm run check:dcb-scope`) shows that as a diff; without one, add `@partitionTag` to slices you expect to move.

### When you still need `@partitionTag`

Inference cannot decide when several ids are left and the chapter does not settle it:

- **A join.** `RecordProductDemand` writes events carrying `productId` and `orderId`. Both are the slice's own ids, and every event in its `ProductDemand` chapter carries both. Only the domain says demand is counted per product.
- **A reference nothing reveals, outside a chapter.** A slice like `PlaceOrder` whose reads never show `customerId` to be a reference, placed directly under `src/StateChange/`, has no chapter to break the tie.

Mark the partition on the **produced event** (`type event`) — not on the command, where it has no effect:

```rescript
// RecordProductDemand.res
@schema
type event =
  | ProductDemandRecorded({@partitionTag productId: string, orderId: string})
  | ProductDemandRevoked({@partitionTag productId: string, orderId: string})
```

In files where `@@reventless.dcbTags` is not active (e.g. event log type definitions outside slice folders), write the schema directly: `orderId: @s.matches(DcbTag.partition) string`. The annotated field stays a DCB tag you can query by.

Without the annotation, the build stops and names the slice:

```text
DCB partition key cannot be inferred — RecordProductDemand: multiple candidate partition keys (orderId, productId) — add an explicit @partitionTag. The ProductDemand chapter does not decide: the ids every event in it carries are [orderId, productId].
```

The other failure reads `… <Slice>: no own partition key — every produced *Id is read from a foreign producer (OrderPlaced declares orderId; …)`. That is almost always a consumed lifecycle arm declaring the id the slice is partitioned by. Remove the field from the consumed arm (write the bare `| OrderPlaced`); add `@partitionTag` only if the slice really is a pure join.

These checks run at deploy (`Dcb_Builder`), at local boot, and when the command Lambda cold-starts — an unresolved partition stops the Lambda from starting rather than storing events under the wrong key. The framework also:

- **fails the build** on a `@partitionTag` that inference contradicts — it names a key the slice only references, or inference derives a different key;
- **logs** a redundant `@partitionTag` (inference derives the same key without it) at info level — remove it;
- **throws** when an event lacks the tag its partition key names, or when two slices write the same event type under different keys.

Two entities in one plugin may each annotate their own key; there is no limit of one `@partitionTag` per plugin.

### Cross-entity reference reads (inferred — no annotation)

The common cross-partition case — "this command references another entity; does it exist / is it valid?" — needs **no tag annotation at all**. You declare the fields and what the slice consumes, and the framework derives the scope and the partition from the whole plugin's slice graph:

```rescript
// AddProduct.res — references a Category. Zero annotations.
@schema
type consumedEvent =
  | ProductAdded({productId: string})        // my own lifecycle
  | CategoryAdded({categoryId: string})      // the category's lifecycle…
  | CategoryArchived({categoryId: string})
@schema
type command = AddProduct({productId: string, name: string, price: Reventless.Money.t, categoryId: string})
@schema
type event   = ProductAdded({productId: string, name: string, price: Reventless.Money.t, categoryId: string})
```

Because `categoryId` is owned by another entity (Category emits `CategoryAdded` keyed by it), the framework infers that `AddProduct` reads it **cross-partition** — the `categoryId` clause reads only the category's lifecycle, never sibling products — and that `categoryId` is **payload** on the emitted `ProductAdded` (so the event is never written to the `categoryId` index). The same subtraction leaves `productId` as the partition. You write no `@crossPartition`, no `@noTag` and no `@partitionTag`.

If you write a redundant or contradictory `@crossPartition` the build logs a diagnostic — a key marked cross-partition that the framework resolves as the slice's *own* partition is flagged as a contradiction.

In this repo, `pnpm run check:dcb-scope` guards all of this for the examples: it fails on an unresolvable slice or a redundant `@partitionTag`, and goldens each plugin's partition key per event type (`partitionKeyByEventType`) in `examples/<example>/schema/dcb-scope.json`.

### Composite partition keys (`@compositePartitionTag`)

When the optimal partition key is formed from **multiple fields concatenated together in declaration order** (e.g. `environment/platform/plugin`), use `@compositePartitionTag` instead of `@partitionTag`. A composite key is never inferred: you declare it, and it applies to the whole plugin's event log rather than per slice.

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
- Requires ≥ 2 annotated fields — throws at startup if only 1 is found.
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

Because each event lives in exactly one partition (its partition key), a
single-tag read of any *other* tag is **partition-scoped** by default — it keeps
that tag's consistency fence narrow. The M:N invariant needs the opposite: read
`studentId` across every course partition the student appears in.

Mark such a tag `@crossPartition` (on the command **and** the produced event —
never on `consumedEvent`). Here the events carry two candidate ids, `courseId` and
`studentId`, so the partition also needs `@partitionTag` on the produced event:

```rescript
// Course-subscription capacity: partition by courseId, read studentId across
// every course partition the student appears in.
@schema
type command =
  | SubscribeStudent({
      courseId: string,                    // partition read — "all of the course"
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

## Identities: one type per id

**In plain words:** declare each entity's id once with `Id.Make`, and type every field that holds it. The compiler then refuses an order id where a customer id belongs. The tags, partitions and references the framework derives stay what they were, because an identity's key is the name those fields already had. See [Id](common-modules/Id.md) for the module itself.

```rescript
// src/Order/OrderId.res — declared in the chapter whose slices decide about it
include Reventless.Id.Make({
  let key = "orderId"
})
```

```rescript
// src/Order/StateChange/PlaceOrder.res
@schema
type command =
  | PlaceOrder({
      orderId: OrderId.t,
      customerId: CustomerId.t,
      productIds: array<CatalogSpec.ProductId.t>,
    })
```

A DCB slice has no identity of its own: it decides about the one its partition field carries, and mentions others. So an identity is declared per **key**, not per slice or per chapter. The chapter is its default home, and a slice partitioned by an identity another chapter declares is reported.

What changes once a field is typed:

- **The tag key follows the type.** A typed field is tagged whatever it is called, and by its identity's key: `buyer: CustomerId.t` writes the `customerId` tag its producers write. `@dcbTag("sellerId")` on a typed field keeps `sellerId`, which is how to retype a field whose stored tag is not its identity's key without migrating data. `@partitionTag`, `@crossPartition` and `@ref` accept typed fields too.
- **Partition inference reads identities**, so the rules above apply to typed fields unchanged. The golden `schema/dcb-scope.json` of the DCB example did not move when the example adopted identities.
- **References are derived.** A typed field with no `@ref` references the one view in the plugin whose rows are keyed by its identity. `@ref` is needed only where several are, and naming a view keyed by another identity is reported.
- **Views are keyed by type.** A StateView declares `module Key = OrderId`, and a projection that sets a row under another id no longer compiles. Without a `Key`, rows stay keyed by `string`.

Adoption is per plugin, and once started it is checked for completeness. `pnpm run check:dcb-scope` reports a field named for one identity but typed as another (`orderId: CustomerId.t`), and an untyped `*Id: string` whose identity the plugin declares. A plugin that types nothing is never reported.

Some ids stay strings, on purpose:

- **Published contracts read by other plugins.** A consumer cannot hold a type it cannot see. Convert with `toString` where you publish, and `makeFromString` where you receive. An identity that both plugins share, like a product id, is declared in the publishing plugin's `*-spec` package instead, and then crosses the boundary typed.
- **`@compositePartitionTag` members.** A member is one segment of a joined key, not an entity's id. Typing one is a compile error.
- **Routing keys.** Automation and outbound to-do rows, and extension routing ids, are keyed by string. Convert where you key them.

## Under the hood

How the shared log, the command topic, the filtering handler, and the per-slice
registration are actually built at deploy time — and why they are built that
way — is framework-side detail. See
[DCB in the framework](/framework/architecture/dcb) for the wiring, the design
decisions behind it, and the known rough edges, and
[DCB consistency checks](/framework/internals/dcb-consistency-checks) for how a
decision's read condition becomes the fences enforced on append.
