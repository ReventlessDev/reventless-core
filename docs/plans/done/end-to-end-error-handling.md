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

**AWS scope**: `publishJsonsAndWait: None` on the AWS path means DCB commands return `Pending`. `entityId` and `eventCount` are not populated. Addressable when AWS sync support is added.

---

## Key Constraints

- **Steps 1–3 are independent of steps 4–6**. The NACKing fix (step 1) and the type/SDL work (steps 2–3) can be merged before any channel implementation lands.
- **Step 4 (in-memory) must land before step 5 (AWS)** — the AWS implementation follows the same pattern but needs the type contract established first.
- **No change to app developer code** for aggregates and StateChangeSlices using the default — the channel is wired by the runtime builder. Only high-contention opt-out requires explicit `SQS_Async` declaration.

## Status

- [x] Step 1 — Fix StateChangeSlice NACKing bug
- [x] Step 2 — Add `commandOutcome` type and `publishJsonsAndWait` to channel adapter
- [x] Step 3 — Add `CommandResult` SDL types; update `CommandGenerator` return type
- [x] Step 4 — `CommandTopicChannel_InMemory`: expose `publishJsonsAndWait`
- [x] Step 5 — Rename/split AWS channel adapters (`SQS_Sync` / `SQS_Async`)
- [x] Step 6 — Switch runtime builder defaults to `SQS_Sync`
- [x] Step 7 — Update examples and documentation
- [x] Step 8 — Extend `CommandAccepted` with `entityId` and `eventCount`
