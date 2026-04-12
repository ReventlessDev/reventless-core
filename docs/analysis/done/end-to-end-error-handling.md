# End-to-End Error Handling in Reventless

## Executive Summary

When a GraphQL mutation triggers a command that the aggregate or StateChangeSlice rejects (via `decide` returning `Error(...)`), the error currently **never reaches the client**. The mutation returns a message ID, processing happens asynchronously, and business rule violations are silently logged. This is a fundamental UX gap: the client has no way to tell the user what went wrong.

This analysis traces the complete error path, identifies all the gaps, and evaluates the options for fixing them — all within the existing GraphQL API surface, with no additional HTTP endpoints.

---

## 1. Current Flow: What Actually Happens

### 1.1 The Happy Path

```
Client                  Backend
  |                       |
  | GraphQL mutation      |
  |  addProduct(...)  --> |
  |                       | publishJsons → CommandTopic (SQS FIFO)
  |                       | returns immediately
  | <-- { data: { addProduct: "msg-uuid" } }
  |                       |
  |                  [async, separate Lambda]
  |                       | CommandTopic handler fires
  |                       | replay event log
  |                       | decide(state, command) → Ok([ProductAdded(...)])
  |                       | append events
  |                       | publish EventTopic → subscription → client
  |
  | <-- subscription: ProductAdded(...)
```

The mutation returns a `msgId` string — the UUID of the message placed on the queue. There is no domain result in the mutation response.

### 1.2 The Error Path (Aggregate)

When `Behavior.decide` returns `Error(e)` in `Aggregate_Callback.processCommand` ([Aggregate_Callback.res:65-69](reventless/reventless-core/src/components/Aggregate/Aggregate_Callback.res#L65-L69)):

```rescript
| Error(error) =>
  let errorJson = error->Message.encode(Spec.errorSchema)->JSON.stringify
  let id = command'.id->Spec.Id.toString
  EffectLogger.logError(~comp, `decide error: ${errorJson} id=${id}`)->Effect.runSync
  Ok((state, events))   // <-- continues as if nothing happened
```

- Error is **logged** (CloudWatch in AWS, console in dev)
- Processing **continues** — subsequent commands in the same batch are processed
- **No events are emitted** — state is unchanged
- The `Ok((state, events))` return makes this indistinguishable from a command that produced no events
- **The error is completely invisible to the caller**

### 1.3 The Error Path (StateChangeSlice)

`StateChangeSlice_Callback.handleSingleCommand` ([StateChangeSlice_Callback.res:128-133](reventless/reventless-core/src/components/StateChangeSlice/StateChangeSlice_Callback.res#L128-L133)):

```rescript
| Error(error) =>
  let errorJson = error->S.reverseConvertToJsonOrThrow(Spec.errorSchema)->JSON.stringify
  EffectLogger.logError(~comp, `decide error=${errorJson}`)->Effect.map(_ => Error(
    errorJson,
  ))
```

Then in the result mapping ([StateChangeSlice_Callback.res:144-149](reventless/reventless-core/src/components/StateChangeSlice/StateChangeSlice_Callback.res#L144-L149)):

```rescript
| Error(_) => Error(reference)   // reference = SQS message reference
```

- The error JSON is captured... then **thrown away**. The `Error(reference)` result just marks the SQS message as "failed" (NACK)
- SQS will retry the message (up to the dead-letter queue limit)
- **The actual error content is lost** after the reference mapping
- **The error is completely invisible to the caller**

### 1.4 What the GraphQL Mutation Returns

The resolver in `CommandGeneratorResolvers_GraphQL.res` ([line 94-95](reventless/reventless-in-memory/src/adapter/CommandGenerator/CommandGeneratorResolvers_GraphQL.res#L94-L95)):

```rescript
let result = await generateCommand(payload)->Effect.runPromise
result->JSON.Encode.string
```

`generateCommand` returns the `msgId`. It throws a JS exception on:
- Schema decode errors (malformed command arguments)
- Command interceptor denials (authorization failures)

But it **does not and cannot** throw on business rule violations — those happen asynchronously, after the queue publish has already succeeded.

### 1.5 Summary of the Gap

| Error Type | Logged | Propagated to Client | SQS Behavior |
|------------|--------|---------------------|--------------|
| Schema decode failure (malformed input) | Yes | Yes (GraphQL error) | Not queued |
| Authorization denied (interceptor) | No | Yes (GraphQL error) | Not queued |
| Business rule violation — Aggregate | Yes | **No** | Message ACKed |
| Business rule violation — StateChangeSlice | Yes | **No** | Message NACKed (retried!) |
| Event log append conflict (after retries) | Yes | **No** | Error(reference) |

**Note on StateChangeSlice NACKing**: A business rule violation in a StateChangeSlice causes the SQS message to be NACKed and retried. Since the decision model hasn't changed between retries (the command is idempotent at the infrastructure level), it will fail the same way on every retry — burning all retries and eventually landing in the dead-letter queue. This is wasteful and misleading.

---

## 2. What Should Happen

### 2.1 Client Expectations by Strategy

From the [rescript-client-architecture analysis](rescript-client-architecture.md), clients use two strategies:

**Online-First**: The client sends a command and **needs to know the result** to:
- Show a validation error message if the business rule was violated
- Roll back an optimistic UI update if the command was rejected
- Disable "pending" state and re-enable the form

**Offline-First**: The client runs `decide` locally first. If local `decide` succeeds, the command is queued and synced. The server-side `decide` runs on the authoritative state — conflicts between client and server decisions **must** be surfaced back so the client can reconcile.

### 2.2 The Ideal Mental Model

The client should see a command as having exactly three outcomes:

1. **Accepted**: The command was valid, business rules were satisfied, events were committed. The entity's state has changed.
2. **Rejected (business rule)**: The command was structurally valid but the domain rejected it. The entity's state did not change. The client receives a typed error value from `Spec.error`.
3. **Failed (infrastructure)**: Something unexpected went wrong (storage unavailable, conflict after max retries, etc.). The client should retry or alert the user.

Currently, outcomes 1 and 2 are **indistinguishable** from the client's perspective. Both look like: "I sent a mutation and got a msgId."

---

## 3. Options and Consequences

### Option A: Synchronous GraphQL Mutation

**What**: The GraphQL mutation waits for `decide` to run before returning — it returns the domain outcome directly in the mutation response. No separate transport, no subscription needed for the common case.

**How it works**:
```
Client → mutation addProduct(id: "p1", name: "Widget", ...)
       → GraphQL resolver runs decide() synchronously against event log
       ← { data: { addProduct: { __typename: "CommandAccepted", msgId: "..." } } }
         or
       ← { data: { addProduct: { __typename: "CommandRejected", msgId: "...", errorCode: "ProductAlreadyExists" } } }
```

The resolver reads the event log, runs `decide`, appends events, and returns the result — all within the same Lambda invocation. No SQS in the critical path for user-facing commands.

**Consequences**:
- **+ Best UX**: The client knows the outcome immediately. Optimistic UI rollback is instant.
- **+ Simplest client code**: The mutation response already contains the full result — no subscription pairing needed.
- **+ Eliminates StateChangeSlice NACKing problem**: Business rule violations are caught and returned before any queue is involved.
- **+ No new API surface**: Same GraphQL mutations, richer return type.
- **− Loses SQS ordering guarantees for user-facing commands**: Commands for the same aggregate are no longer serialized by SQS FIFO. Optimistic locking (sequenceNr / DCB condition) still prevents conflicts, but contention increases under high load for the same entity.
- **− Higher mutation latency**: Each mutation incurs a DynamoDB read (replay) + write (append) synchronously. Under low contention this is ~20-50ms; under high contention with retries, it degrades.
- **− EventTopic fan-out still async**: Downstream effects (read model projections, other subscriptions) are still asynchronous. The mutation returns success before downstream projections have caught up.

**Verdict**: Ideal for user-facing CRUD commands. SQS FIFO remains the right channel for internal automation and high-throughput write streams — those are not user-facing and don't need synchronous results. See section 7 for how to support both under a unified GraphQL API.

---

### Option B: Command Result via GraphQL Subscription (Fire-and-Forget + Notification)

**What**: Keep fire-and-forget but add a `onCommandResult` subscription that the server publishes to after processing.

**How it works**:
```graphql
mutation {
  addProduct(...) # returns msgId: "abc"
}

subscription {
  onCommandResult(msgId: "abc") {
    accepted
    errorCode
  }
}
```

**Consequences**:
- **+ No architecture change**: Command path stays async. Just adds a new event type and subscription.
- **+ Typed errors**: The server sends the `Spec.error` value back via the subscription.
- **− Requires subscription for every command**: Client code becomes complex — every mutation needs a paired subscription listener.
- **− Race condition**: The client must open the subscription before the result arrives. If processing is fast, the result may fire before the subscription is active.
- **− Still needs optimistic UI rollback pathway**: Two-phase (send → wait for result) means the UI is blocked or must do provisional updates.
- **− StateChangeSlice NACKing still broken**: A rejected command is retried 3 times before a result is published. This adds seconds of latency before the client learns the error.
- **− Subscription infrastructure required**: AppSync or graphql-yoga subscriptions must be deployed and working.

**Verdict**: Viable as a secondary notification channel (e.g., for long-running workflow steps), but poor as the primary error-handling mechanism for CRUD-style commands.

---

### Option C: Typed Error in GraphQL Mutation Response (Single Shared Union)

**What**: Change the GraphQL mutation return type from `String` (just msgId) to a single shared `CommandResult` union used by every mutation. The error payload is opaque to GraphQL — it carries the variant name (`errorCode`) and optionally the full serialized JSON (`errorDetail`). No per-command result type is needed.

**Current schema**:
```graphql
type Mutation {
  addProduct(id: ID!, name: String!, ...): String   # returns msgId
}
```

**New schema**:
```graphql
# Defined once, shared by all mutations
union CommandResult = CommandAccepted | CommandRejected

type CommandAccepted {
  msgId: ID!
}

type CommandRejected {
  msgId: ID!
  errorCode: String!    # variant name, e.g. "ProductAlreadyExists"
  errorDetail: String   # full serialized Spec.error JSON (optional, for debugging)
}

type Mutation {
  addProduct(id: ID!, name: String!, ...): CommandResult!
  placeOrder(orderId: ID!, ...): CommandResult!
  # all mutations return the same union
}
```

The `errorCode` is just the variant constructor name from `Spec.error` — already available as a string from the JSON serialization. The error payload varies per aggregate/slice but the GraphQL wrapper type doesn't — the client switches on `__typename` and then reads `errorCode` to know what happened. Full type safety for the error variant lives in the shared ReScript spec package, not in the SDL.

This requires the mutation to be synchronous (same requirement as Option A) — you can only return an `accepted/rejected` distinction if you've waited for `decide` to run.

**Consequences**:
- **+ Single shared type, no per-command SDL complexity**: `CommandResult` is defined once in the schema. SDL auto-derivation only needs to emit the return type name, not the structure of each aggregate's error type.
- **+ Type-safe enough for clients**: The client switches on `__typename`, then reads `errorCode` as a string. Full type safety for the error variant lives in the shared ReScript spec package.
- **+ No subscription required for command results**: Request-response within the mutation.
- **− Requires synchronous command path** (same tradeoffs as Option A).
- **− `errorCode` is a string, not a GraphQL enum**: Richer typing would require deriving a per-aggregate enum from `Spec.errorSchema`, which needs extra SDL generation work. The string is sufficient for most clients.

**Verdict**: Option A + a trivial SDL change. All mutations return the same shape; the framework just needs to emit an object instead of a bare string. No per-command schema work needed. This is what Options A and C converge to.

---

### Option D: Minimal Fix — Pass-Through Error in Current Async Path

**What**: Without changing the command architecture, surface `decide` errors by:
1. Publishing a `CommandRejected` event on the EventTopic after a business rule violation (Aggregate path)
2. ACKing the SQS message instead of NACKing on business errors (StateChangeSlice path)
3. Delivering the rejection to the client via the existing event subscription

**Aggregate fix** (in `Aggregate_Callback.processCommand`):
```rescript
| Error(error) =>
  let errorJson = error->Message.encode(Spec.errorSchema)->JSON.stringify
  publishRejection(~msgId=command'.meta.msgId, ~error=errorJson)  // non-blocking
  Ok((state, events))   // still no domain events emitted
```

**StateChangeSlice fix** (in `StateChangeSlice_Callback.handleSingleCommand`):
```rescript
| Error(error) =>
  let errorJson = error->S.reverseConvertToJsonOrThrow(Spec.errorSchema)->JSON.stringify
  publishRejection(~msgId=command'.meta.msgId, ~error=errorJson)
  Effect.succeed(Ok("rejected"))  // ACK the message — don't retry a business rule violation
```

**Client subscribes to `onCommandResult(msgId)` to learn about failures** — same subscription as Option B.

**Consequences**:
- **+ No architecture change**: Fire-and-forget stays. Only the error handling inside the callback changes.
- **+ Fixes the StateChangeSlice NACKing bug**: Business rule violations no longer cause infinite retries.
- **+ No new infrastructure required**: Uses the existing EventTopic subscription mechanism.
- **− Still async**: Client still can't roll back optimistic UI until the rejection event arrives (~100ms–seconds after the mutation).
- **− Requires subscription infrastructure**: Client must open a subscription before sending the mutation to avoid the race condition.
- **− Partial fix**: Does not change the fundamental fire-and-forget model.

**Verdict**: A valuable standalone bug fix for the StateChangeSlice NACKing problem. Should be implemented regardless of which other option is chosen. Pairs naturally with Option B for the async notification channel.

---

### Option E: Pre-validation at Command Entry Point

**What**: Run `decide` at the command entry point (in `generateCommand`, before publishing to SQS) as a **pre-validation check** against a read model snapshot.

**How it works**:
```rescript
// In CommandGenerator_Callback, before publishJsons:
let snapshot = await queryDb.getState(id)  // read model snapshot (fast, eventually consistent)
switch Spec.decide(snapshot, command) {
| Error(error) =>
  // Fast rejection — no SQS involved — returned as GraphQL mutation error
  JsError.throwWithMessage(error->JSON.stringify)
| Ok(_) =>
  publishJsons([{id, meta, commandJson}])
  ->Effect.map(_ => meta.msgId)
}
```

**Consequences**:
- **+ Fast rejection for common cases**: Business rule violations caught before SQS, synchronously in the mutation response.
- **− Snapshot may be stale**: The read model is eventually consistent. False positives (command rejected but should have been accepted) and false negatives (command accepted but will be rejected authoritatively) are both possible.
- **− Double processing**: The command is processed twice — once for pre-validation, once authoritatively in the consumer.
- **− Couples command path to read side**: The command generator would need a QueryDb dependency.
- **− Does not eliminate the async error path**: Stale-snapshot false negatives still need handling.

**Verdict**: Viable as a UX optimization for stable, low-write-rate entities where the snapshot is reliably fresh. Not a complete solution — the authoritative async path must still handle errors correctly. Best used only in combination with Option D.

---

## 4. Interaction with the Client Architecture

From [rescript-client-architecture.md](rescript-client-architecture.md), the online-first client assumes a synchronous command response with a typed result. That analysis uses HTTP POST notation for illustration, but the same contract applies directly to a GraphQL mutation returning `CommandResult`:

**Online-first command dispatch** (via GraphQL mutation):
```graphql
mutation AddProduct($id: ID!, $name: String!, $description: String!, $price: Float!) {
  addProduct(id: $id, name: $name, description: $description, price: $price) {
    __typename
    ... on CommandAccepted { msgId }
    ... on CommandRejected { msgId errorCode errorDetail }
  }
}
```

The client switches on `__typename`:
- `CommandAccepted` → confirm optimistic update
- `CommandRejected` → roll back optimistic update, show `errorCode` to user

This design requires **Option A + C** — the mutation must wait for `decide` before returning.

### For the offline-first client

The offline-first client runs `decide` locally against its local event log. When it syncs with the server, the server may also reject commands (state diverged while offline). The sync GraphQL mutation must carry rejections per command in its response:

```graphql
mutation SyncCommands($commands: [CommandInput!]!) {
  syncCommands(commands: $commands) {
    newCursor
    results {
      msgId
      __typename
      ... on CommandAccepted { msgId }
      ... on CommandRejected { msgId errorCode }
    }
  }
}
```

The client then needs to "rebase" local events, removing or flagging rejected commands and re-applying the remaining ones. This requires synchronous server-side validation per command — fire-and-forget cannot produce a per-command result array.

---

## 5. Recommended Path

### Immediate (Non-Breaking Bug Fix)

**Fix the StateChangeSlice NACKing bug** (Option D, partial):
- In `StateChangeSlice_Callback.handleSingleCommand`, when `decide` returns `Error`, return `Ok("rejected")` instead of `Error(errorJson)` — this ACKs the SQS message and prevents infinite retries.
- Log the business error as before.
- Impact: small, non-breaking, fixes a silent operational problem regardless of what else is done.

### Short-Term

**Make GraphQL mutations synchronous and return `CommandResult`** (Options A + C combined):
- The `CommandTopic_Adapter.channel` gains an optional `publishJsonsAndWait` field (see section 7). The `SyncChannel` implementation runs the handler inline; the `AsyncChannel` (SQS FIFO) leaves it `None`.
- All mutations return `CommandResult` instead of bare `String`. The SDL changes from `addProduct(...): String` to `addProduct(...): CommandResult!`.
- `CommandResult` is a three-member union: `CommandAccepted | CommandRejected | CommandPending` (the third for async channels — see section 7).
- `errorCode` carries the `Spec.error` variant name as a string; `errorDetail` carries the full JSON for debugging.
- Full type safety for error variants lives in the shared ReScript spec package.
- Internal automation (EventTopic → Automation → CommandTopic) continues to use the SQS async path — it is not user-facing and does not go through the GraphQL mutation resolver.

### Not Recommended as Primary Approach

- **Option B (subscription-based result)**: Too complex for the common case. Retain only as an opt-in mechanism for long-running workflow notifications.
- **Option E alone (pre-validation)**: Solves the wrong problem. The staleness risk creates a false sense of safety. Useful only as a UX optimization on top of an already-synchronous command path.

---

## 6. Error Taxonomy

| Category | Source | Current Handling | Recommended Handling |
|----------|--------|-----------------|---------------------|
| **Structural errors** | Malformed command arguments (schema decode failure) | GraphQL error (synchronous) | No change needed |
| **Authorization errors** | Command interceptor denial | GraphQL error (synchronous) | No change needed |
| **Business rule violations** | `decide` returns `Error(Spec.error)` | Logged, silently dropped | `CommandRejected` in mutation response |
| **Concurrency conflicts** | Append fails after max retries | Logged, `Error(reference)` | Synchronous retry; surface as GraphQL error |
| **Infrastructure errors** | Storage unavailable, Lambda timeout | CloudWatch, dead-letter queue | No client path possible; alert via monitoring |

Only the first two categories currently reach the client. The goal is to add the third.

---

## 7. Combining Synchronous and Async Execution: A Hybrid Channel Design

The question of which mode to use — fire-and-forget SQS FIFO or synchronous execution — is not a binary choice at the application level. It is a **per-aggregate / per-slice configuration decision** made at deploy time, and the two modes coexist under a unified GraphQL API surface.

### 7.1 Why Both Modes Are Needed

| Scenario | Best Mode | Reason |
|----------|-----------|--------|
| User-facing CRUD (add product, update name) | **Sync** | Immediate error feedback; low contention; UX requires knowing the result |
| High-throughput write streams (IoT events, batch imports) | **Async (SQS FIFO)** | Ordering guarantees; resilience to Lambda cold starts; decoupled retry |
| Internal automation (EventTopic → Automation → CommandTopic) | **Async (SQS FIFO)** | Not user-facing; ordering within a workflow matters |
| Payment / financial commands | **Sync** | Idempotency and immediate confirmation required |
| Cross-aggregate choreography (saga steps) | **Async (SQS FIFO)** | Reliable delivery and retry more important than latency |

### 7.2 The Right Extension Point: `CommandTopic_Adapter.channel`

The `CommandTopic_Adapter.channel` record is already the abstraction boundary ([CommandTopic_Adapter.res](reventless/reventless-core/src/components/CommandTopic/CommandTopic_Adapter.res)):

```rescript
type channel<'callbackEvent, 'context, 'channelParts, 'runtimeParts> = {
  parts: 'channelParts,
  resources: array<ReventlessInfra.Adapter.resource>,
  publishJsons: Pulumi.Output.t<CommandTopic.publishJsons>,          // fire-and-forget
  publishJsonsStream: Pulumi.Output.t<CommandTopic.publishJsonsStream>,
  handleChannelEvent: CommandTopic.jsonCommandsHandler => ...,
  connect: connect<...>,
}
```

`publishJsons` is typed as `array<commandJson> => promise<unit>` — it publishes and returns nothing. To support a synchronous result path, the channel gains an optional companion:

```rescript
// New optional field on the channel record
publishJsonsAndWait: option<Pulumi.Output.t<CommandTopic.publishJsonsAndWait>>

// New type
type commandOutcome =
  | Accepted({msgId: string})
  | Rejected({msgId: string, errorCode: string, errorDetail: option<string>})

type publishJsonsAndWait = array<commandJson> => promise<array<commandOutcome>>
```

The `option` makes it backward-compatible: existing channel implementations leave it `None` (async-only). A sync channel sets it to `Some(...)`.

### 7.3 Channel Implementations and Naming

The AWS adapters are renamed to make the distinction explicit. The existing `CommandTopicChannel.res` re-export module exposes both:

| Module alias | Underlying file | Queue type | `publishJsonsAndWait` | Default for |
|---|---|---|---|---|
| `CommandTopicChannel.SQS_Sync` | `CommandTopicChannel_SQS_Sync.res` | Standard SQS | `Some(...)` — waits for handler result | Aggregates, StateChangeSlices (new default) |
| `CommandTopicChannel.SQS_Async` | `CommandTopicChannel_SQS_Async.res` | FIFO SQS | `None` — fire-and-forget | High-contention / internal automation (opt-in) |

`CommandTopicChannel_SQS_Sync` (standard SQS queue + inline handler result):
```rescript
// publishJsons becomes a thin wrapper — discards result for internal callers
publishJsons: async jsons => {
  let _ = await publishJsonsAndWait(jsons)
},
// publishJsonsAndWait runs the handler inline and returns typed outcomes
publishJsonsAndWait: Some(async jsons => {
  let stream = Stream.fromIterable(jsons->Array.map(toTopicItem))
  let results = await handler(stream)->Effect.runPromise
  results->Array.map(toCommandOutcome)
})
```

`CommandTopicChannel_SQS_Async` (FIFO SQS queue, current behavior):
```rescript
publishJsonsAndWait: None   // not supported — caller gets CommandPending
```
The `CommandGenerator` sees `None` and returns a `CommandPending` response.

**Why standard SQS for the sync channel**: When the handler runs inline (no queue involved in the critical path), FIFO ordering guarantees are irrelevant — the call is synchronous within a single Lambda invocation. A standard SQS queue is still provisioned as the backing store for the CommandTopic (used by internal async callers such as automation), but FIFO-specific configuration (`contentBasedDeduplication`, `deduplicationScope`, `fifoThroughputLimit`) is not needed and is omitted.

### 7.4 Common GraphQL API: Three-Member `CommandResult` Union

Both channel types expose the same GraphQL mutations. A third union member, `CommandPending`, represents the async case — the command has been queued but the result is not yet known:

```graphql
# Defined once, shared by all mutations
union CommandResult = CommandAccepted | CommandRejected | CommandPending

type CommandAccepted {
  msgId: ID!
}

type CommandRejected {
  msgId: ID!
  errorCode: String!    # Spec.error variant name, e.g. "ProductAlreadyExists"
  errorDetail: String   # full serialized Spec.error JSON (optional, for debugging)
}

type CommandPending {
  msgId: ID!            # use msgId to subscribe for the eventual result
}

type Mutation {
  # Same return type regardless of which channel is configured underneath
  addProduct(id: ID!, name: String!, description: String!, price: Float!): CommandResult!
  placeOrder(orderId: ID!, customerId: ID!, productIds: [ID!]!): CommandResult!
}
```

The resolver in `CommandGeneratorResolvers_GraphQL.res` changes from returning `JSON.Encode.string(msgId)` to returning a `CommandResult` object:

```rescript
// Current:
let result = await generateCommand(payload)->Effect.runPromise
result->JSON.Encode.string   // just the msgId

// New:
let outcome = await generateCommand(payload)->Effect.runPromise
outcome->commandOutcomeToJson
// → { "__typename": "CommandAccepted", "msgId": "..." }
// → { "__typename": "CommandRejected", "msgId": "...", "errorCode": "ProductAlreadyExists" }
// → { "__typename": "CommandPending",  "msgId": "..." }
```

`generateCommand` checks whether `publishJsonsAndWait` is available on the channel:
1. `Some(publishAndWait)` → call it, wait for result, return `CommandAccepted` or `CommandRejected`
2. `None` → call `publishJsons`, return `CommandPending`

### 7.5 Client Handling of All Three Outcomes

```rescript
// Online-first client handling a mutation result
let handleCommandResult = (result, ~rollback, ~onError) =>
  switch result.__typename {
  | "CommandAccepted" =>
    confirmOptimistic()
  | "CommandRejected" =>
    rollback()
    onError(result.errorCode)
  | "CommandPending" =>
    // Async channel: optimistic update stays visible; subscribe for confirmation
    subscribeToCommandResult(result.msgId,
      ~onAccepted=confirmOptimistic,
      ~onRejected=rollback,
    )
  | _ => ()
  }
```

This is a single code path. Adding sync channels to an aggregate later doesn't require client changes — the `__typename` switch already handles all three cases.

### 7.6 In-Memory Already Implements This

The in-memory `CommandTopicChannel_InMemory` is already effectively synchronous — `Bus.dispatchCommand` runs the handler in the same process ([CommandTopicChannel_InMemory.res](reventless/reventless-in-memory/src/adapter/CommandTopic/CommandTopicChannel_InMemory.res)):

```rescript
let publishJsons: CommandTopic.publishJsons = async jsons => {
  let _ = await jsons->Array.map(async cmdJson =>
    await Bus.dispatchCommand(name, encodeMessage(cmdJson))
  )->Promise.all
}
```

The in-memory channel can expose `publishJsonsAndWait` immediately by capturing the handler result from `Bus.dispatchCommand`. This means the local dev environment and tests get full synchronous error propagation **before** any AWS implementation is done.

### 7.7 AWS Deployment: Lambda Strategies

The synchronous channel requires the GraphQL resolver Lambda to execute the handler logic inline.

**Single runtime strategy** (`AggregateRuntime_Builder_Single`): All aggregates share one Lambda — the same function that handles the GraphQL mutation can run `handleCommands` directly. No cross-function invocation needed. This is the natural fit for `SyncChannel`.

**PerAggregate strategy**: The API Lambda and aggregate Lambda are separate. A synchronous channel requires Lambda-to-Lambda synchronous invocation from the API Lambda to the aggregate Lambda (~5-10ms overhead). Alternatively, a lightweight version of the handler is bundled into the API Lambda for sync invocations.

```
Single runtime strategy:
  GraphQL Lambda (mutation resolver + aggregate handler bundled)
    → SQS_Sync: run handler inline → CommandAccepted | CommandRejected
    → SQS_Async: publish to SQS FIFO → CommandPending

PerAggregate runtime strategy:
  GraphQL Lambda (mutation resolver)
    → SQS_Sync: invoke Aggregate Lambda synchronously → CommandAccepted | CommandRejected
    → SQS_Async: publish to SQS FIFO → CommandPending
  Aggregate Lambda (handler)
    → processes commands from standard SQS (SQS_Sync internal path)
      OR from SQS FIFO (SQS_Async path)
```

Internal automation always uses the SQS path regardless of strategy — it bypasses the GraphQL resolver entirely.

### 7.8 Configuration Pattern

Channel choice is set at component creation for both Aggregates and StateChangeSlices. `CommandTopicChannel.SQS_Sync` is the default in `reventless-aws` — app code only needs to opt out explicitly when high-contention ordering is required.

**Aggregate:**
```rescript
// Default — sync channel (standard SQS), immediate CommandResult
module ProductAggregate = Aggregate_Builder.Make(
  ProductSpec, ProductBehavior, CommandTopicChannel.SQS_Sync,
)

// Opt-in — async channel (FIFO SQS), returns CommandPending
module InventoryAggregate = Aggregate_Builder.Make(
  InventorySpec, InventoryBehavior, CommandTopicChannel.SQS_Async,
)
```

**StateChangeSlice (DCB):**

StateChangeSlices wire their CommandTopic at the DcbEventLog level via `Dcb_Builder`. The channel is passed there, and each slice that handles commands inherits it:

```rescript
// Default — sync channel (standard SQS), immediate CommandResult
module ItemCatalogLog = DcbEventLog_Builder.Make(
  ItemCatalogSpec, CommandTopicChannel.SQS_Sync,
)

// Opt-in — async channel (FIFO SQS), returns CommandPending
module OrderLog = DcbEventLog_Builder.Make(
  OrderSpec, CommandTopicChannel.SQS_Async,
)
```

Individual StateChangeSlices within the same DcbEventLog share the channel configured on that log — the channel is per-event-log, not per-slice. If some slices need sync and others need async ordering, they belong on separate DcbEventLogs.

The `CommandTopicChannel.res` re-export module (currently `module SQS = CommandTopicChannel_SQS` and `module SQS_FIFO = CommandTopicChannel_SQS_FIFO`) is updated to:

```rescript
module SQS_Sync  = CommandTopicChannel_SQS_Sync   // standard SQS, sync result — default
module SQS_Async = CommandTopicChannel_SQS_Async  // FIFO SQS, fire-and-forget — opt-in
```

The runtime builders (`AggregateRuntime_Builder_Single`, `AggregateRuntime_Builder_PerAggregate`, `AggregateRuntime_Builder_Micro`) currently hardcode `CommandTopicChannel.SQS_FIFO`. They switch to `CommandTopicChannel.SQS_Sync` as the default. `DcbCommandTopicEntryPoint` and `PluginExtensionPointRuntime_Builder` (which used `CommandTopicChannel.SQS`) switch to `CommandTopicChannel.SQS_Sync` as well — ExtensionPoint command topics are user-facing and benefit from synchronous results.

Different aggregates and DcbEventLogs in the same plugin can use different channels. The GraphQL API is unified — callers see only `CommandResult`. The `__typename` is the observable difference.

### 7.9 Contention as Configuration, Not Discovery

**Contention profile is known at design time, not runtime.** No adaptive switching is needed:

- Entity type with many concurrent writers (inventory counters, seat reservations) → `CommandTopicChannel.SQS_Async` at deploy time
- Entity type with one owner (a product catalog entry, a user profile) → `CommandTopicChannel.SQS_Sync` (the default — no explicit declaration needed)

The DCB vs Aggregate decision guide (`docs/guides/aggregate-vs-dcb-decision-guide.md`) already encodes this reasoning: high-contention cross-entity scenarios use DCB; self-contained lifecycles use Aggregates. The same classification guides channel selection. Static configuration keeps behavior predictable and adds no runtime overhead.

---

## 8. Extending `CommandAccepted` with `entityId` and `eventCount`

### 8.1 Motivation

A bare `CommandAccepted { msgId }` tells the client the command succeeded but not what changed or where to find it. Two additions make acceptance actionable without extra round-trips:

- **`entityId: ID`** — the aggregate or primary entity ID, so the client can navigate to a detail view, update a local cache entry, or open an optimistic update immediately after acceptance.
- **`eventCount: Int!`** — the number of events emitted. `0` means the command was idempotent (state already matched the intent — `decide` returned `Ok([])`). `1+` means real state change occurred. Without this, the client cannot distinguish "saved" from "already up to date".

Updated SDL:

```graphql
type CommandAccepted {
  msgId: ID!
  entityId: ID      # absent for DCB cross-entity and extension point commands (see below)
  eventCount: Int!  # 0 for idempotent no-ops
}
```

Updated ReScript type (`CommandTopic.res`):

```rescript
type commandOutcome =
  | Accepted({msgId: string, entityId?: string, eventCount: int})
  | Rejected({msgId: string, errorCode: string, errorDetail?: string})
  | Pending({msgId: string})
```

### 8.2 Aggregates: straightforward

For aggregate commands the envelope `id` IS the aggregate ID. In `CommandGenerator_Callback.res:44`:

```rescript
let id = payload.arguments.id
```

Every aggregate GraphQL mutation has a top-level `id: ID!` argument — the aggregate root identifier. It is already in hand when the outcome is constructed. `eventCount` flows back from the handler via `publishJsonsAndWait`. No architectural changes beyond threading both values into `Accepted`.

### 8.3 DCB StateChangeSlices: the `id` gap

DCB StateChangeSlice mutations do **not** have a top-level `id` argument. The entity identity is embedded inside the command payload as a DCB-tagged field:

```rescript
// AddProduct (single-entity): productId is the only tagged field
type command = AddProduct({productId: string, name: string, ...})

// PlaceOrder (cross-entity): orderId is @partitionTag, productId[] are read-side prerequisites
type command = PlaceOrder({@partitionTag orderId: string, @noDcbTag customerId: string, productId: array<string>})
```

`payload.arguments.id` is therefore `undefined` for DCB mutations. Setting `entityId` from the envelope `id` would always produce an absent field.

### 8.4 Returning the `@partitionTag` value for DCB

The `@partitionTag` field is the natural `entityId` for a DCB command — it identifies the primary entity the command targets (`productId` for `AddProduct`, `orderId` for `PlaceOrder`). Both the field name and its value are derivable from data already in flight.

#### Option A — Extract at `CommandGenerator` level (pre-dispatch)

`makeGenerateCommand` builds `commandJson` from `payload.arguments` before publishing. For `StateChangeSlice` commands it could call `DcbTag.extractTagsFromJson(commandSchema, commandJson)` to find tagged fields, then `DcbTag.extractPartitionTagFields(commandSchema)` to identify the partition key field, and return its value as `entityId`.

**Limitation**: `eventCount` is not available at this point — the handler hasn't run yet. Option A solves `entityId` only; `eventCount` still requires threading from the handler. Doing two partial changes creates more surface area than one complete change.

#### Option B — Widen `handleSingleCommand` return type (recommended)

`StateChangeSlice_Callback.handleSingleCommand` already computes everything needed:

- **`eventCount`**: `newEvents->Array.length` at line 84 — available when `decide` returns `Ok(newEvents)`.
- **`entityId`**: the `query` built at lines 51–55 already contains the partition tag value. `DcbTag.getPartitionTagValue(query, partitionTag)` extracts it. The partition tag key is derivable once per `Make(Spec)` functor from `Spec.eventSchema` via `DcbTag.derivePartitionTag([("", "", Spec.eventSchema->S.castToUnknown)])`.

The return type changes from `result<string, string>` to `result<acceptedResult, string>`:

```rescript
type acceptedResult = {entityId?: string, eventCount: int}
```

This propagates upward through the dispatch chain:

| Layer | File | Change |
|---|---|---|
| Callback | `StateChangeSlice_Callback.res` | `handleSingleCommand` returns `result<acceptedResult, string>` |
| Bus | `InMemory_Bus.res` | dispatch result carries `acceptedResult` for accepted outcomes |
| Channel | `CommandTopicChannel_InMemory.res` | map to `Accepted({..., entityId, eventCount})` |
| Outcome type | `CommandTopic.res` | `Accepted` variant extended (Step 8 of plan) |

### 8.5 Client value

**Single-entity DCB slices** (`AddProduct`, `ShipOrder`, `ChangeProductName`) are the common case. The `@partitionTag` unambiguously identifies one entity. The client gets `productId` / `orderId` / etc. directly in the mutation response:

```graphql
mutation {
  addProduct(productId: "prod-123", name: "Widget", ...) {
    ... on CommandAccepted {
      entityId   # "prod-123"
      eventCount # 1
    }
    ... on CommandRejected {
      errorCode  # "ProductAlreadyExists"
    }
  }
}
```

**Cross-entity slices** (`PlaceOrder` with `orderId` + `productId[]`): a cross-entity slice reads events belonging to multiple entity types in a single DCB query — `PlaceOrder` reads both `Order` events (to detect duplicate placement) and `CatalogProduct` events (to validate the requested products exist). Only one of those entity types is actually being written to: the new `Order`. The others are consulted read-only as inputs to the decision model.

The `@partitionTag` annotation on `orderId` makes this explicit — it marks the field whose value becomes the storage partition key, i.e. the entity being written. The array-tagged `productId[]` fields expand into separate query clauses that read existing `CatalogProduct` events but never produce new events for those entities.

`entityId = orderId` is therefore the correct and unambiguous navigation target. The client already knows the product IDs (it sent them in the command) and has no use for them in the response. The new order's ID is what the client needs to navigate to the order confirmation view or update its local state.

```graphql
mutation {
  placeOrder(orderId: "ord-456", customerId: "cust-1", productId: ["p1", "p2"]) {
    ... on CommandAccepted {
      entityId   # "ord-456" — navigate to order detail; product IDs already known by client
      eventCount # 1
    }
    ... on CommandRejected {
      errorCode  # "OrderAlreadyPlaced" | "ProductsNotAvailable"
    }
  }
}
```

Technically `entityId` could also be absent here — the client generated `orderId` before sending the command, so it already has it. But returning it makes the API consistent with single-entity slices and eliminates any ambiguity about which ID to use for navigation.

**Composite partition key slices**: some entities are scoped within a parent — a product within a tenant, a line item within an order. A single `productId` field is not globally unique; the storage partition key must combine multiple fields (e.g., `tenantId + "/" + productId`). This is expressed via `@compositePartitionTag` annotations on each contributing field:

```rescript
@schema type event =
  | ProductAdded({
      @compositePartitionTag tenantId: string,   // position 0, sep "/"
      @compositePartitionTag productId: string,  // position 1
      name: string,
    })
// Partition key: "tenant-a/prod-123"
```

Returning this composite key as `entityId` is valuable and consistent with the pattern for all other DCB slices:

- **GraphQL `ID` fields are opaque by contract.** The client uses `entityId` as a navigation token for a subsequent `node(id: ...)` query or as a Relay cache key — it does not need to decompose it into component parts. A composite string is a perfectly valid opaque ID from the client's perspective.
- **The client may not already hold the key.** For single-entity slices the client generates the entity ID itself. For composite keys, one component is often session-derived (`tenantId` comes from auth context, not an explicit command argument) and another may be server-generated. The client cannot safely reconstruct the composite key without knowing the separator and field order — returning it is the only reliable contract.
- **Consistency.** All DCB slice types returning `entityId` is simpler for clients than a rule that says "single-entity: present, cross-entity: present, composite: absent".

The implementation requires handling the `Composite` case that `getPartitionTagValue` does not cover. `derivePartitionTagV2` (used at `Make(Spec)` functor time) already returns `Simple(partitionTag)` or `Composite({keys, seps})`. The extraction becomes a dispatch on that result:

```rescript
// Inside Make(Spec) — computed once at module init:
let derivedPartitionTag = DcbTag.derivePartitionTagV2([("", "", Spec.eventSchema->S.castToUnknown)])

// Inside handleSingleCommand — after query is built:
let entityId = switch derivedPartitionTag {
| Simple(pt) => DcbTag.getPartitionTagValue(query, pt)
| Composite(spec) =>
  let tags = DcbTag.extractTags(Spec.commandSchema, command'.command)
  Some(DcbTag.getCompositePartitionKeyValue(tags, spec))
}
```

The composite key value (`"tenant-a/prod-123"`) is then returned in `acceptedResult.entityId` and surfaces as `CommandAccepted.entityId` in the GraphQL response. The client treats it as an opaque `ID` — no parsing required.

**`eventCount = 0`** — distinguishes real acceptance from idempotent no-ops. A command that produces `Ok([])` is accepted but nothing changed. Without `eventCount`, the client cannot differentiate "saved" from "already up to date" — a material UX difference for retry-safe operations.

### 8.6 Constraints

- **AWS path**: `publishJsonsAndWait: None` means DCB commands return `Pending` on AWS. `entityId` and `eventCount` are not populated on the AWS path. Consistent with current aggregate behaviour — addressable when AWS sync support is added.
- **Extension point commands**: there are three distinct reasons why `entityId` is absent for EP commands, and they compound on each other.

  **What an EP command dispatch actually does.** When a client sends an EP mutation, the command travels to the extension point's CommandTopic. `ExtensionPoint_Callback.handleIncomingCommands` collects the batch, runs it through every registered `Mapping` module's `mapIncomingCommand` function, and executes the resulting `abstractCommandAction` values concurrently. Each action is either an `AbstractPublishCommand(aggregateName, reference, cmdJson)` — which fires the encoded command at the named aggregate's CommandTopic — or an `AbstractCall` side-effect. Crucially, `applyCommandAction` uses the aggregate's existing `publishJsons` (fire-and-forget), not `publishJsonsAndWait`. The EP callback returns `Ok(reference)` as soon as the downstream publish call is dispatched, without waiting for the target aggregate to run `decide`.

  **The `CommandAccepted` an EP mutation returns does not mean the target aggregate accepted the command.** It means the extension point successfully executed the mapping and dispatched to the target(s). The actual aggregate decisions happen asynchronously, after the EP mutation has already returned. This is a fundamental difference from aggregate and DCB slice commands, where `publishJsonsAndWait` waits for `decide` to complete.

  **Fan-out: zero, one, or many target entities.** `mapIncomingCommand` returns `array<commandAction>` — the mapping is free to produce any number of downstream commands. A single EP command can dispatch to multiple aggregates with different entity IDs (fan-out), or produce no downstream commands at all if the mapping decides to ignore the input. There is no single target entity to name as `entityId`.

  **The EP envelope `id` is the source-side identity, not the target.** The `id` in the EP command envelope (`payload.arguments.id`) is the identity of the entity in the extension point's domain — for example, the order ID in an ordering EP. The target aggregate command's `id` is whatever the mapping extracts and places in `cmdJson` — it could be the same value, a different value derived from the payload, or different IDs for each fan-out target. These are separate identities at separate layers.

  For completeness: if EP dispatch were made end-to-end synchronous (waiting for all target aggregate decisions), returning `entityId` would require returning an array of outcomes — one per target. That is a richer API design beyond the current `CommandResult` union and not in scope here.
- **Cross-entity array tag queries**: `PlaceOrder` has `productId: array<string>`. The query has one clause per product ID plus the `orderId` clause. `getPartitionTagValue` correctly finds `orderId` from the clause whose tag key matches the partition tag — array tags land in separate clauses and do not interfere.
- **Composite partition key extraction**: uses `DcbTag.extractTags` on the command value rather than reading from the query, because `buildQueryFromCommand` does not preserve composite-member tags as individual clauses. The command value is available in `handleSingleCommand` as `command'.command`, so this is straightforward.

---

## 9. Channel Configuration Granularity: Aggregates vs StateChangeSlices

### 9.1 How Aggregates Are Configured

Each AWS runtime builder for aggregates hardcodes a channel module at the top level:

```rescript
// AggregateRuntime_Builder_Single.res
module CommandTopicChannel = CommandTopicChannel.SQS_Sync
```

This flows down through the functor stack: `Aggregate_Builder.Make` receives the channel module and passes it to `CommandTopic_Builder.Make`, which calls `Channel.make(~name, ~opts)` to create the concrete channel. In principle, different aggregate types could use different channels, though the AWS builders currently all default to `SQS_Sync`.

The available options are:

| Channel | Queue | Mutation result | Use when |
|---|---|---|---|
| `SQS_Sync` (default) | Standard SQS | `CommandAccepted` \| `CommandRejected` | User-facing CRUD — inline synchronous result |
| `SQS_Async` | FIFO SQS | `CommandPending` | High-contention writes where FIFO ordering matters more than a synchronous result |

### 9.2 How StateChangeSlices Are Configured

StateChangeSlices are grouped at plugin construction time into two arrays: sync (standard SQS, `CommandAccepted` / `CommandRejected`) and async (FIFO SQS, `CommandPending`):

```rescript
// Plugin.make — explicit grouping at the call site
Plugin.make(
  ~stateChangeSlices=[module(AddProductSlice), module(RenameCategorySlice)],
  ~asyncStateChangeSlices=[module(HighContentionSlice)],  // opt-in to FIFO
  ...
)
```

`Dcb_Builder.Make` accepts **two** `CommandTopic_Adapter.Channel` functor parameters — one for sync slices, one for async slices. Both are always required for type-checking, but a CommandTopic (and the backing SQS queue) is only provisioned when the corresponding slice array is non-empty. Platforms that never use async slices simply pass the same channel twice and no FIFO queue is created.

### 9.3 Why the Contention Model Differs

The "high-contention" concern has a different character for each component type:

**Aggregates** process all commands for a given instance sequentially in one Lambda invocation (commands are grouped by aggregate ID before replay/process/append). Under high write volume to the same instance, concurrent Lambdas can produce conflicting sequence numbers. `SQS_Async` (FIFO) solves this by serialising dispatch: at most one command for a given message group is in-flight at a time, eliminating the retry loop for aggregate conflicts.

**StateChangeSlices** use optimistic concurrency with a conditional-append condition and a retry loop (up to `maxRetries = 3`). Conflicts are expected and handled in-process — no Lambda-level queuing is needed. `SQS_Async` would reduce retry frequency (at most one command in-flight per partition) but would remove the synchronous `CommandAccepted` / `CommandRejected` response, which is the primary value of the DCB path's `publishJsonsAndWait`. The built-in retry loop is the idiomatic DCB contention strategy.

**Summary**: `SQS_Async` is the right escape valve for aggregates under high write pressure. For StateChangeSlices, the optimistic concurrency + retry model is the intended high-contention strategy; `SQS_Async` would trade away synchronous results without removing the need for conflict handling.

### 9.4 Per-Slice Channel Configuration — Implemented

**Status: Implemented (Step 10).**

The critical insight proved correct: **the handler registry does not need to be split** — `makeFilteringHandler` routes commands by type name from `CommandTopic_Helpers.globalRegistry`, which is consulted regardless of which CommandTopic (and therefore which SQS queue) the command arrived on. Both the sync and async CommandTopics share the same registry and the same handler functions. The only split is where the *mutation resolver* enqueues the command.

#### Implemented design: two CommandTopics, explicit array grouping

`Dcb_Builder.Make` was extended to accept a second channel parameter:

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

Rather than a per-slice `dispatchMode` annotation (which would have required PPX changes), the implementation uses **explicit array separation** at the `construct()` call site:

```rescript
DcbBuilder.construct(
  ~stateChangeSlices=[module(AddProductSlice), module(RenameCategorySlice)],
  ~asyncStateChangeSlices=[module(HighContentionSlice)],
  ...
)
```

This is simpler, requires no PPX changes, and makes the grouping visible at the call site. The previous concern about "PPX must ship first" does not apply.

Phase 2 routing:
- `stateChangeSlices` → sync `dcbCommandTopic.ops.publishJsonsAndWait` → `CommandAccepted | CommandRejected`
- `asyncStateChangeSlices` → async `dcbAsyncCommandTopic.ops.publishJsons` → `CommandPending`

#### `derivedPartitionTag` — no new spec field needed

The concern about needing `let derivedPartitionTag` on `StateChangeSlice.T` was resolved: `StateChangeSlice_Callback.Make(Spec)` **already computes** `derivedPartitionTag` at functor init time from `Spec.eventSchema`:

```rescript
// Inside StateChangeSlice_Callback.Make — computed once at functor init
let derivedPartitionTag = Reventless.DcbTag.derivePartitionTag([
  (Spec.name, Spec.moduleUrl, Spec.eventSchema->S.castToUnknown),
])
```

This is used for `entityId` extraction in `handleSingleCommand` — it derives the partition key value from the command, which becomes the `entityId` in `CommandAccepted`. No new field on the module type and no PPX injection required.

#### FIFO group key (future work)

The dynamic FIFO group key (partition tag value as `MessageGroupId`) was not implemented in this step — the async path currently uses the standard `publishJsons` without per-message group keys. If per-entity FIFO ordering is needed in the future, `CommandTopicChannel_SQS_Async` would need to accept a group key per message. The `derivedPartitionTag` already computed in `StateChangeSlice_Callback` provides all the information needed to extract it from the command JSON.

#### Breaking change at platform level

Every `Dcb_Builder.Make(...)` call site gained a second required channel parameter. Platforms that only use sync slices pass the same channel twice — no FIFO queue is provisioned because `asyncStateChangeSlices` defaults to `[]`.
