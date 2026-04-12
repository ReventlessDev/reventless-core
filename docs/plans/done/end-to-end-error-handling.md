# Plan: End-to-End Error Handling

**Analysis**: [docs/analysis/done/end-to-end-error-handling.md](../analysis/done/end-to-end-error-handling.md)

## Overview

Implement synchronous command results in GraphQL mutations so business rule violations reach the client. The approach: add `publishJsonsAndWait` to the `CommandTopic_Adapter.channel` abstraction; rename the AWS adapters to `CommandTopicChannel_SQS_Sync` (standard SQS, default) and `CommandTopicChannel_SQS_Async` (FIFO SQS, opt-in); update `CommandGenerator` to return a `CommandResult` union instead of a bare `msgId` string.

## Steps

### Step 1 — Fix StateChangeSlice NACKing bug

**File**: `reventless/reventless-core/src/components/StateChangeSlice/StateChangeSlice_Callback.res:128–133`

In `handleSingleCommand`, when `decide` returns `Error`, return `Ok("rejected")` instead of `Error(errorJson)`. This ACKs the SQS message and stops the infinite retry loop. Log the error as before.

```rescript
| Error(error) =>
  let errorJson = error->S.reverseConvertToJsonOrThrow(Spec.errorSchema)->JSON.stringify
  EffectLogger.logError(~comp, `decide error=${errorJson}`)->Effect.map(_ => Ok("rejected"))
```

**Scope**: `reventless-core` only. Non-breaking — no API or schema changes.

---

### Step 2 — Add `commandOutcome` type and `publishJsonsAndWait` to `CommandTopic`

**Files**:
- `reventless/reventless-core/src/components/CommandTopic/CommandTopic.res`
- `reventless/reventless-core/src/components/CommandTopic/CommandTopic_Adapter.res`

Add the new types to `CommandTopic.res`:

```rescript
type commandOutcome =
  | Accepted({msgId: string})
  | Rejected({msgId: string, errorCode: string, errorDetail: option<string>})
  | Pending({msgId: string})

type publishJsonsAndWait = array<Message.commandJson> => promise<array<commandOutcome>>
```

Add the optional field to the `channel` record in `CommandTopic_Adapter.res`:

```rescript
type channel<...> = {
  // ... existing fields ...
  publishJsonsAndWait: option<Pulumi.Output.t<CommandTopic.publishJsonsAndWait>>,
}
```

All existing channel implementations set `publishJsonsAndWait: None` — backward-compatible, no breakage.

**Scope**: `reventless-core`, `reventless-spec` (if types land there), `reventless-in-memory`, `reventless-aws` (compilation only — they add `None` to their channel records).

---

### Step 3 — Add `CommandResult` SDL types and update `CommandGenerator`

**Files**:
- `reventless/reventless-core/src/components/CommandGenerator/CommandGenerator_Callback.res`
- `reventless/reventless-in-memory/src/adapter/CommandGenerator/CommandGeneratorResolvers_GraphQL.res`
- `reventless/reventless-in-memory/src/adapter/GraphQL/GraphQL_Server.res` (or wherever SDL base types are registered)

**SDL fragment** (registered once at server startup):

```graphql
union CommandResult = CommandAccepted | CommandRejected | CommandPending

type CommandAccepted {
  msgId: ID!
}

type CommandRejected {
  msgId: ID!
  errorCode: String!
  errorDetail: String
}

type CommandPending {
  msgId: ID!
}
```

Update `makeGenerateCommand` in `CommandGenerator_Callback.res` to accept an optional `publishJsonsAndWait` and return a `commandOutcome` instead of a `string`:

```rescript
// New return type of generateCommand
type commandGenerator = CommandGenerator.payload => Effect.t<CommandTopic.commandOutcome, ...>

// Logic:
->Effect.flatMap(((meta, commandJson, id)) => {
  // ... interceptor check unchanged ...
  switch channel.publishJsonsAndWait {
  | Some(publishAndWait) =>
    Effect.promise(() => publishAndWait([{id, meta, commandJson}]))
    ->Effect.map(outcomes => outcomes->Array.getUnsafe(0))
  | None =>
    Effect.promise(() => publishJsons([{id, meta, commandJson}]))
    ->Effect.map(_ => Pending({msgId: meta.msgId}))
  }
})
```

Update the resolver in `CommandGeneratorResolvers_GraphQL.res` to return a `CommandResult` object:

```rescript
// Old:
result->JSON.Encode.string

// New:
outcome->commandOutcomeToJson
// → { "__typename": "CommandAccepted", "msgId": "..." }
// → { "__typename": "CommandRejected", "msgId": "...", "errorCode": "...", "errorDetail": null }
// → { "__typename": "CommandPending",  "msgId": "..." }
```

Update all mutation SDL registrations to use `CommandResult!` as the return type instead of `String`.

**Scope**: `reventless-core` (CommandGenerator types), `reventless-in-memory` (GraphQL resolver + SDL).

---

### Step 4 — Implement `CommandTopicChannel_SQS_Sync` (in-memory first)

Start with the in-memory adapter since it already runs the handler inline.

**File**: `reventless/reventless-in-memory/src/adapter/CommandTopic/CommandTopicChannel_InMemory.res`

Expose `publishJsonsAndWait` by capturing the handler result from `Bus.dispatchCommand`. The bus already returns the handler result — it just needs to be surfaced:

```rescript
publishJsonsAndWait: Some(
  (publishJsonsAndWait->Pulumi.Output.make : Pulumi.Output.t<CommandTopic.publishJsonsAndWait>)
)
```

where `publishJsonsAndWait` calls `Bus.dispatchCommand` and maps the `array<result<string, string>>` back to `array<commandOutcome>`.

This gives the local dev and test environment full synchronous error propagation immediately, before any AWS work.

**Scope**: `reventless-in-memory` only.

---

### Step 5 — Rename and split AWS CommandTopic channel adapters

**In `reventless/reventless-aws/src/adapter/CommandTopic/`**:

| Old file | New file | Change |
|---|---|---|
| `CommandTopicChannel_SQS.res` | `CommandTopicChannel_SQS_Sync.res` | Add `publishJsonsAndWait: Some(...)` — runs handler inline |
| `CommandTopicChannel_SQS_FIFO.res` | `CommandTopicChannel_SQS_Async.res` | Add `publishJsonsAndWait: None` |
| `CommandTopicChannel.res` | `CommandTopicChannel.res` | Update re-exports: `module SQS_Sync` / `module SQS_Async` |

`CommandTopicChannel_SQS_Sync` uses a **standard SQS queue** (no FIFO). The inline handler execution is synchronous — FIFO ordering at the queue level is irrelevant when the handler runs in the same Lambda invocation. The queue still exists as backing infrastructure for internal async callers (automation, etc.).

`CommandTopicChannel_SQS_Async` is the renamed `CommandTopicChannel_SQS_FIFO` — FIFO queue, fire-and-forget, no change to behavior.

The `CommandTopicChannel_SQS_Runtime.res` shared runtime helpers remain unchanged.

**Scope**: `reventless-aws`.

---

### Step 6 — Switch runtime builder defaults to `SQS_Sync`

All runtime builders currently hardcode a channel. Update them to use `CommandTopicChannel.SQS_Sync`:

| File | Current | New |
|---|---|---|
| `AggregateRuntime_Builder_Single.res` | `CommandTopicChannel.SQS_FIFO` | `CommandTopicChannel.SQS_Sync` |
| `AggregateRuntime_Builder_PerAggregate.res` | `CommandTopicChannel.SQS_FIFO` | `CommandTopicChannel.SQS_Sync` |
| `AggregateRuntime_Builder_Micro.res` | `CommandTopicChannel.SQS_FIFO` | `CommandTopicChannel.SQS_Sync` |
| `PluginExtensionPointRuntime_Builder.res` | `CommandTopicChannel.SQS` | `CommandTopicChannel.SQS_Sync` |
| `ExtensionPointRuntime_Builder_PerExtensionPoint.res` | `CommandTopicChannel.SQS` | `CommandTopicChannel.SQS_Sync` |

`DcbCommandTopicEntryPoint` and the DCB runtime path also switch to `SQS_Sync`.

**Scope**: `reventless-aws` (runtime builders only).

---

### Step 7 — Update examples and documentation

- Update `examples/online-shop-aggregates/` and `examples/online-shop-dcb/` to use `CommandTopicChannel.SQS_Sync` (or verify they inherit from the runtime builder default and need no change).
- Any example that explicitly used `SQS_FIFO` for high-contention reasons switches to `CommandTopicChannel.SQS_Async` with a comment explaining why.
- Update `packages/doc/docs/` — component docs for Aggregate, StateChangeSlice, and CommandGenerator to describe `CommandResult` and the channel configuration pattern.
- Update `docs/guides/platform-and-plugin-guide.md` with the new channel configuration section.

---

### Step 8 — Extend `CommandAccepted` with `entityId` and `eventCount`

**Motivation**: After acceptance, the client often needs to navigate to the affected entity or confirm that the command produced actual state change (vs. an idempotent no-op returning `Ok([])`). Both fields are derivable from data already in-flight at acceptance time — no extra round-trips required.

**SDL change** (`CommandAccepted` type):

```graphql
type CommandAccepted {
  msgId: ID!
  entityId: ID      # absent for extension point commands (see below)
  eventCount: Int!  # 0 for idempotent no-ops
}
```

**ReScript type change** (`CommandTopic.res`):

```rescript
type commandOutcome =
  | Accepted({msgId: string, entityId?: string, eventCount: int})
  | Rejected({msgId: string, errorCode: string, errorDetail?: string})
  | Pending({msgId: string})
```

**`entityId` by command type:**

- **Aggregate commands** — envelope `id` IS the aggregate ID (`CommandGenerator_Callback.res:44`: `let id = payload.arguments.id`). Available immediately, no extra work.

- **DCB single-entity slices** (`AddProduct`, `ShipOrder`) — entity identity is the `@partitionTag` field inside the command payload, not the envelope `id`. Populated via `DcbTag.getPartitionTagValue(query, partitionTag)` inside `handleSingleCommand`, where `query` is already built.

- **DCB cross-entity slices** (`PlaceOrder` with `orderId` + `productId[]`) — the `@partitionTag` (`orderId`) identifies the entity being written; `productId[]` are read-only decision inputs. `entityId = orderId` is the correct navigation target. `getPartitionTagValue` correctly resolves it from the query despite array-tag clauses.

- **DCB composite partition key slices** — no single `@partitionTag` field; `derivePartitionTagV2` returns `Composite({keys, seps})`. The constructed composite key (e.g. `"tenant-a/prod-123"`) is returned as an opaque `ID` via `DcbTag.getCompositePartitionKeyValue(tags, compositeSpec)`. Clients treat it as an opaque navigation token — no decomposition required.

- **Extension point commands** — `entityId` is absent. Three compounding reasons: (1) the EP callback dispatches to target aggregates fire-and-forget (`publishJsons`, not `publishJsonsAndWait`), so `CommandAccepted` means "mapping executed and dispatched", not "target aggregate accepted"; (2) `mapIncomingCommand` can fan out to zero, one, or many target aggregates — there is no single entity ID to return; (3) the EP envelope `id` is the source-side identity in the EP's domain, which is not the same as any target aggregate's entity ID.

**Implementation — DCB path (Option B, recommended):**

Widen `handleSingleCommand` return type from `result<string, string>` to `result<acceptedResult, string>`:

```rescript
type acceptedResult = {entityId?: string, eventCount: int}
```

`entityId` is extracted from the already-built `query` using a dispatch on `derivePartitionTagV2`:

```rescript
// Computed once at Make(Spec) functor init:
let derivedPartitionTag = DcbTag.derivePartitionTagV2([("", "", Spec.eventSchema->S.castToUnknown)])

// Inside handleSingleCommand, after query is built:
let entityId = switch derivedPartitionTag {
| Simple(pt) => DcbTag.getPartitionTagValue(query, pt)
| Composite(spec) =>
  let tags = DcbTag.extractTags(Spec.commandSchema, command'.command)
  Some(DcbTag.getCompositePartitionKeyValue(tags, spec))
}
```

**Files to update**:
- `reventless/reventless-core/src/components/CommandTopic/CommandTopic.res` — extend `Accepted` variant
- `reventless/reventless-core/src/components/CommandGenerator/CommandGenerator_Callback.res` — populate `entityId` from envelope `id` for aggregates; leave absent for DCB (comes from handler via outcome)
- `reventless/reventless-core/src/components/StateChangeSlice/StateChangeSlice_Callback.res` — widen `handleSingleCommand` return to carry `entityId` and `eventCount`; dispatch on `derivePartitionTagV2` for the `Simple` / `Composite` cases
- `reventless/reventless-in-memory/src/InMemory_Bus.res` — thread `acceptedResult` through dispatch
- `reventless/reventless-in-memory/src/adapter/CommandTopic/CommandTopicChannel_InMemory.res` — map to `Accepted({..., entityId, eventCount})`
- `reventless/reventless-in-memory/src/adapter/CommandGenerator/CommandGeneratorResolvers_GraphQL.res` — update `commandOutcomeToJson`
- `reventless/reventless-in-memory/src/adapter/GraphQL/` (wherever `CommandResult` SDL is registered) — update `CommandAccepted` type definition

**AWS scope**: `entityId` and `eventCount` are not yet wired on the AWS path. Addressable in step 9.

---

### Step 9 — Harmonize inline dispatch; fix `eventCount` for Aggregates

**Motivation**: Step 8 wired the side-channel for DCB slices in the in-memory adapter only. Two gaps remain:
1. The AWS `CommandTopicChannel_SQS_Sync` has the same inline-handler path but returns `Accepted({msgId, eventCount: 0})` with no `entityId` for DCB slices.
2. `Aggregate_Callback` never calls `reportAccepted`, so `eventCount` is always 0 even when events were appended.
3. Both channel adapters (in-memory and AWS) contain identical `encodeMessage` and dispatch-then-collect logic — this duplication should be extracted.

**Approach — shared helper in `CommandTopic_Helpers`:**

Move `commandOutcome` and `publishJsonsAndWait` types from `CommandTopic.res` into `CommandTopic_Helpers.res` (re-exported via `include`). Add two new helpers there:

```rescript
// Encode the full message body expected by CommandTopic_Callback.
// Shared by both in-memory and SQS_Sync channels.
let encodeCommandJson = (cmdJson: Reventless.Message.commandJson): JSON.t =>
  JSON.Encode.object(Dict.fromArray([
    ("id", JSON.Encode.string(cmdJson.id)),
    ("meta", cmdJson.meta->S.reverseConvertToJsonOrThrow(Reventless.Message.metaSchema)),
    ("command", cmdJson.commandJson),
  ]))

// Runs handleCmds inline, manages the acceptedResultChannel side-channel,
// and maps results to commandOutcome. Shared by both channel adapters.
let runInlineAndCollect: (
  array<Reventless.Message.commandJson>,
  jsonCommandsHandler,
) => promise<array<commandOutcome>>
```

Both `CommandTopicChannel_InMemory` and `CommandTopicChannel_SQS_Sync` call `ReventlessCore.CommandTopic.runInlineAndCollect(jsons, handleCmds)` in their `publishJsonsAndWait` and remove their local `encodeMessage`.

`CommandTopicChannel_InMemory` also replaces `encodeMessage` in `publishJsons` with `ReventlessCore.CommandTopic.encodeCommandJson`.

**Fix `eventCount` for Aggregates:**

Add `CommandTopic_Helpers.reportAccepted` calls in `Aggregate_Callback.replayProcessAppend` at both branches where results are returned:

```rescript
// No-events (idempotent):
| [] =>
  references->Array.forEach(reference =>
    CommandTopic_Helpers.reportAccepted(reference, {entityId: idStr, eventCount: 0})
  )
  EffectLogger.logInfo(...)

// Successful append:
| Ok(_) =>
  references->Array.forEach(reference =>
    CommandTopic_Helpers.reportAccepted(reference, {
      entityId: idStr,
      eventCount: generatedEvents'->Array.length,
    })
  )
  EffectLogger.logInfo(...)
```

Uses `CommandTopic_Helpers.reportAccepted` (not `CommandTopic.reportAccepted`) to avoid pulling `Adapter` → `@pulumi/pulumi` into the aggregate callback's import chain.

**Files to update**:
- `reventless/reventless-core/src/components/CommandTopic/CommandTopic_Helpers.res` — move types, add `encodeCommandJson` + `runInlineAndCollect`
- `reventless/reventless-core/src/components/CommandTopic/CommandTopic.res` — remove now-redundant type definitions
- `reventless/reventless-core/src/components/Aggregate/Aggregate_Callback.res` — add `reportAccepted` calls
- `reventless/reventless-in-memory/src/adapter/CommandTopic/CommandTopicChannel_InMemory.res` — use shared helpers
- `reventless/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Sync.res` — use shared helpers

**Notes**:
- `entityId` for aggregates is still filled by `CommandGenerator_Callback` from the envelope `id` — unchanged.
- `PerAggregate` strategy falls back to `Pending` (handler not registered in resolver Lambda) — no change needed.
- The side-channel is set/cleared synchronously around `handleCmds` — thread-safe within a single Lambda invocation.
- `reportAccepted` is a no-op when `acceptedResultChannel` is `None` (SQS batch processing path), so no cross-path interference.

---

### Step 10 — Per-slice async channel configuration *(superseded by Step 11)*

**Reference**: Analysis §9.4 — [docs/analysis/done/end-to-end-error-handling.md](../analysis/done/end-to-end-error-handling.md#94-adding-per-slice-channel-configuration-if-needed)

Allow individual StateChangeSlices to opt into `SQS_Async` (FIFO) while the rest of the platform retains synchronous `CommandAccepted` / `CommandRejected` results. Applies to slices with very high write contention on a single entity partition where the retry loop alone is insufficient.

#### Implemented design (to be replaced by Step 11)

**`Dcb_Builder.Make` — second channel parameter for async slices:**

```rescript
module Make = (
  DcbEventLogStorage: DcbEventLog_Adapter.Storage,
  DcbEventTopicPublisher: EventTopic_Adapter.Publisher,
  DcbCommandTopicChannel: CommandTopic_Adapter.Channel,           // sync
  DcbCommandTopicChannelAsync: CommandTopic_Adapter.Channel,      // async (FIFO)
  RuntimeBuilder: PluginRuntime_Builder.T,
  HooksConfig: Plugin_Helpers.HooksConfig,
)
```

Both channel modules are always required as functor arguments (ReScript functors need concrete module types for type-checking), but `Dcb_Builder` only calls `CommandTopic.make(...)` for a given channel if at least one slice uses that mode — no SQS queue is provisioned for an unused mode.

**`Dcb_Builder.construct` — explicit array separation (not per-slice annotation):**

The design evaluated per-slice `dispatchMode` annotation but opted for explicit array separation — simpler, no PPX changes required, and the grouping is visible at the call site:

```rescript
DcbBuilder.construct(
  ~name,
  ~stateChangeSlices=[module(AddProductSlice), module(RenameCategorySlice)],
  ~asyncStateChangeSlices=[module(HighContentionSlice)],  // FIFO, CommandPending
  ...
)
```

Slices in `stateChangeSlices` use the sync CommandTopic → `publishJsonsAndWait` → `CommandAccepted | CommandRejected`.
Slices in `asyncStateChangeSlices` use the async CommandTopic → `publishJsons` → `CommandPending`.

Both CommandTopics share the same `makeFilteringHandler` → `CommandTopic_Helpers.globalRegistry` — handlers are registered once, no duplication.

**`derivedPartitionTag`** is already computed inside `StateChangeSlice_Callback.Make(Spec)` at functor init from `Spec.eventSchema` — no new field on `StateChangeSlice.T` and no PPX changes were needed.

#### Files changed

- `reventless-core`: `Dcb_Builder.res` (6-param Make, lazy async CommandTopic, dual-Lambda setup), `Plugin_Builder.res` (forward `DcbCommandTopicChannelAsync`), `Platform_Admin.res` (add `DcbCommandTopicChannelAsync` functor param)
- `reventless-aws`: `Plugin.res` (pass `CommandTopicChannel.SQS_Async`), `Platform.res` (pass `CommandTopicChannel.SQS_Async` to `Platform_Admin.Make`)
- `reventless-in-memory`: `Plugin_Builder.res` (pass second `CommandTopicChannel_InMemory.Make(Bus)`), `Platform.res` (same)

---

### Step 11 — Unified `MakeAsync` pattern for StateChangeSlices and Aggregates

**Motivation**: Step 10 introduced `~asyncStateChangeSlices` as a second array at the `Plugin.make` call site. This creates an asymmetry with aggregates, where the async variant will be expressed as `Platform.Aggregate.MakeAsync(...)` — both sync and async modules going in the same `~aggregates` array. Step 11 aligns both component types to the same pattern: a `MakeAsync` builder, single array.

#### Design

**StateChangeSlice** — add `let isAsync: bool` to `StateChangeSlice.T`:

```rescript
// reventless-infra/StateChangeSlice.res — module type T
let isAsync: bool
```

`Platform.StateChangeSlice.Make(Spec)` sets `let isAsync = false`.  
`Platform.StateChangeSlice.MakeAsync(Spec)` is defined as:

```rescript
module MakeAsync = (Spec: ReventlessInfra.StateChangeSlice.Spec) => {
  include Make(Spec)
  let isAsync = true
}
```

`Plugin.make` exposes only `~stateChangeSlices` (the `asyncStateChangeSlices` parameter is removed). `Dcb_Builder.construct` receives the single array and partitions it internally:

```rescript
let syncSlices = stateChangeSlices->Array.filter((module M: StateChangeSlice.T) => !M.isAsync)
let asyncSlices = stateChangeSlices->Array.filter((module M: StateChangeSlice.T) => M.isAsync)
```

Infrastructure provisioning logic is unchanged — sync CommandTopic created only if `syncSlices` non-empty, async only if `asyncSlices` non-empty.

**Aggregate** — add `Platform.Aggregate.MakeAsync`:

Each aggregate has its own CommandTopic, so the channel choice is fully self-contained in the module. `Platform.Aggregate.MakeAsync(Spec, Behavior, Mappings)` is the same as `Make` but wired with `SQS_Async` instead of `SQS_Sync`. Both `Make` and `MakeAsync` return `Aggregate.T` and go in `~aggregates`.

In the AWS platform, this means a second runtime builder variant: `AggregateRuntime_Builder_Single_Async` (or `_PerAggregate_Async`, `_Micro_Async`) with `module CommandTopicChannel = CommandTopicChannel.SQS_Async`. In the in-memory platform, the channel is already the same for sync and async (`CommandTopicChannel_InMemory`), so `MakeAsync` is identical to `Make`.

#### App developer DX after Step 11

```rescript
// StateChangeSlices — single array, MakeAsync encodes the intent
module AddProduct = Platform.StateChangeSlice.Make(AddProduct)
module HighContention = Platform.StateChangeSlice.MakeAsync(HighContention)

// Aggregates — single array, same pattern
module Product = Platform.Aggregate.Make(Product, ProductBehavior, NoMappings.Make(Product))
module HotAggregate = Platform.Aggregate.MakeAsync(HotAgg, HotBehavior, NoMappings.Make(HotAgg))

Platform.Plugin.make(
  ~stateChangeSlices=[module(AddProduct), module(HighContention)],
  ~aggregates=[module(Product), module(HotAggregate)],
  ...
)
```

#### Files to change

**Revert / replace `asyncStateChangeSlices`:**
- `reventless-infra/StateChangeSlice.res` — add `let isAsync: bool` to `module type T`
- `reventless-core/StateChangeSlice_Builder.res` — add `let isAsync = false` to `Make`
- `reventless-core/Dcb_Builder.res` — replace `~asyncStateChangeSlices` param with internal partition of `~stateChangeSlices` by `isAsync`
- `reventless-core/Plugin_Builder.res` — remove `~asyncStateChangeSlices` from `construct` and `make`; remove from `DcbBuilder.construct` call
- `reventless-core/Plugin.res` — remove `~asyncStateChangeSlices` from `module type T`
- `reventless-infra/Plugin.res` — remove `~asyncStateChangeSlices` from `module type T`
- `reventless-core/Platform_Admin.res` — expose `MakeAsync` alongside `Make` in `Platform.StateChangeSlice`
- `reventless-aws/Plugin.res` and `Platform.res` — expose `MakeAsync` in `Platform.StateChangeSlice`
- `reventless-in-memory/Plugin_Builder.res` and `Platform.res` — expose `MakeAsync`

**Add `Aggregate.MakeAsync`:**
- `reventless-aws/adapter/Runtime/AggregateRuntime_Builder_Single_Async.res` — clone of `_Single` with `SQS_Async`
- `reventless-aws/adapter/Runtime/AggregateRuntime_Builder_PerAggregate_Async.res` — clone of `_PerAggregate` with `SQS_Async`
- `reventless-aws/adapter/Runtime/AggregateRuntime_Builder_Micro_Async.res` — clone of `_Micro` with `SQS_Async`
- `reventless-aws/Platform.res` and `Plugin.res` — expose `Platform.Aggregate.MakeAsync`
- `reventless-in-memory/Platform.res` and `Plugin_Builder.res` — expose `Platform.Aggregate.MakeAsync` (same as `Make`)

**Guides and docs:**
- `docs/guides/dcb-usage.md` — replace `asyncStateChangeSlices` array with `MakeAsync` pattern; update `Plugin_Builder.Make` functor params (remove `DcbCommandTopicChannelAsync`, it's still needed internally but no longer exposed through plugin API)
- `docs/guides/platform-and-plugin-guide.md` — update async aggregate and slice sections to show `MakeAsync`
- `packages/doc/docs-app/plugin-system.md` — remove `~asyncStateChangeSlices` row from parameters table; add note that async variants use `MakeAsync` builder
- `packages/doc/docs-app/concepts/dcb.md` — update async slice example from array-separation to `MakeAsync`
- `packages/doc/docs-app/dcb-slices.md` — update Step 3 (plugin assembly) if it shows `asyncStateChangeSlices`
- `packages/doc/docs-app/aggregates.md` — add section on `MakeAsync` for high-contention aggregates

---

## Key Constraints

- **Steps 1–3 are independent of steps 4–6**. The NACKing fix (step 1) and the type/SDL work (steps 2–3) can be merged before any channel implementation lands.
- **Step 4 (in-memory) must land before step 5 (AWS)** — the AWS implementation follows the same pattern but needs the type contract established first.
- **No change to app developer code** for aggregates and StateChangeSlices using the default — the channel is wired by the runtime builder. Only high-contention opt-out requires explicit `MakeAsync`.

## Status

- [x] Step 1 — Fix StateChangeSlice NACKing bug
- [x] Step 2 — Add `commandOutcome` type and `publishJsonsAndWait` to channel adapter
- [x] Step 3 — Add `CommandResult` SDL types; update `CommandGenerator` return type
- [x] Step 4 — `CommandTopicChannel_InMemory`: expose `publishJsonsAndWait`
- [x] Step 5 — Rename/split AWS channel adapters (`SQS_Sync` / `SQS_Async`)
- [x] Step 6 — Switch runtime builder defaults to `SQS_Sync`
- [x] Step 7 — Update examples and documentation
- [x] Step 8 — Extend `CommandAccepted` with `entityId` and `eventCount`
- [x] Step 9 — Harmonize inline dispatch; fix `eventCount` for Aggregates
- [x] Step 10 — Per-slice async channel configuration (superseded by Step 11)
- [x] Step 11 — Unified `MakeAsync` pattern for StateChangeSlices and Aggregates
