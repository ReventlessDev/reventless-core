# Plan: Real-Time Change Descriptors

## Status: Not started

This plan extends the existing AppSync Events subscription infrastructure (built in [graphql-subscriptions-appsync.md](graphql-subscriptions-appsync.md), Source B complete) so read-model change publication scales to many subscribers viewing different slices of the same read model. It changes what is published, where (channel layout), and adds the metadata WebSocket clients need to safely update lists, details, and paginated views without polling.

---

## Motivation

`graphql-subscriptions-appsync.md` Phase 4 ships a working publish chain:

```
DynamoDB Stream → StateTopic_AppSync Lambda → POST /event /default/{topicName} → AppSync Events
```

But the published payload is the full new entity state (`NewImage` after unmarshal), and the channel is one-per-QueryDb (`/default/{readModelName}`, e.g. `/default/catalog-Product`). For a client rendering 50 entities across 5 partitions — say, an admin console list view scoped to one tenant or one environment — this means:

- **Every subscriber receives every change** to the read model regardless of which partition they're viewing — fanout cost is O(clients × changes), not O(viewers × changes).
- **Every payload carries the full state** — for a 50-field projection with nested arrays this is hundreds of KB per change × N subscribers.
- **No dedup signal** — DynamoDB Streams at-least-once redelivery results in two identical publishes; the client refetches twice.
- **No coalescing** — a bulk operation that touches 500 entities produces 500 published events per subscriber.

The framework needs a different shape: **partition-scoped channels carrying small change descriptors**, with optional server-side coalescing for bursts and a monotonic dedup key. Any WebSocket client (admin console, end-user app, mobile, AI agent) consumes the same shape.

---

## Scope

| Capability | In | Out |
|---|---|---|
| Per-read-model AppSync Events namespace | ✅ | — |
| Partition-scoped channel layout (`{rm}/{partition}/{entityId}`) | ✅ | — |
| Change-descriptor payload format (`changeKind`, `id`, `partitionKey`, etc.) | ✅ | — |
| Server-side coalescing (`BulkInvalidated`) via OnPublish handler | ✅ | — |
| DCB position exposure to projector handlers | ✅ | — |
| `Plugin_FooItemsByIds(ids: [String!]!)` batched query per read model | ✅ | — |
| Resolution of client-side WebSocket `Sec-WebSocket-Protocol` blocker | ✅ | — |
| Tenant-isolation auth at subscribe time (`OnSubscribe` handler hook) | ✅ (hook only — handler shipped by commercial extension) | Extension policy |
| Client implementation | — | Out of scope — this plan covers the publish path and channel layout only |
| In-memory (yoga) parity | ✅ (lightweight mock) | Full feature match with prod |

---

## Background: where the existing infrastructure stands

From `graphql-subscriptions-appsync.md` Phase 4 (deployed and verified):

- `QueryDbStorage_DynamoDbStream` enables streams (`NEW_AND_OLD_IMAGES`) on per-read-model DynamoDB tables.
- `StateTopic_AppSync.res` creates a Lambda + IAM role + EventSourceMapping per QueryDb. The Lambda:
  - Skips `REMOVE` events.
  - Unmarshals `NewImage`.
  - POSTs to `/event` on the AppSync Events endpoint, channel `/default/{topicName}` (underscore→hyphen normalised because Events channels forbid underscores).
- One AppSync Events API resource per platform (`AppSync_EventsApi`).
- `Plugin_SubscriptionSchema.res` generates `oncatalog_Product_stateChanged(id: ID): catalog_Product` SDL fields — informational only for Sources A/B (no `@aws_subscribe`); clients use the Events WebSocket, not the GraphQL WebSocket.

Verified facts:

- The publish chain works end-to-end (DDB write → Lambda → 200 OK from AppSync Events `POST /event`).
- The Lambda handler uses native SigV4 + fetch (not the nonexistent `@aws-sdk/client-appsync-events` SDK referenced in the original plan).
- `subscriptionInfraHook` in `Platform.res` is the wiring point that installs StateTopic Lambdas per stream-enabled QueryDb.

Blocked:

- WebSocket subscriber `Sec-WebSocket-Protocol` format — all attempted variants returned `SubProtocolNotSupportedError`. No client has successfully connected yet.

---

## Architectural changes

### 1. Channel layout

Today: `/default/{readModelName}` — flat, one channel per read model. Tomorrow:

```
namespace: default
channels:  {readModelName}/{partitionKey}/{entityId}      # one channel per entity-change
           {readModelName}/{partitionKey}/_meta            # bulk events (BulkInvalidated, partition-wide)
```

Concrete examples:

```
Catalog-Product/dev-Shop/product-abc-123        # change to one product
Catalog-Product/dev-Shop/_meta                   # bulk invalidation for the partition
Platform-Plugin/dev-Shop/Catalog                 # change to the Catalog plugin entity
```

Channel limits (AppSync Events): 5 segments × 50 chars/segment. Two-segment partition keys (`dev-Shop`) fit comfortably; composite IDs that use `/` as an internal separator need to be percent-encoded or hashed to fit within one segment.

Wildcard subscriptions:

- `Catalog-Product/dev-Shop/*` — list view subscribes; receives every change in that partition.
- `Catalog-Product/dev-Shop/product-abc-123` — detail view subscribes; receives only this entity's changes.
- `Catalog-Product/dev-Shop/_meta` — meta channel for partition-level events; wildcard above also matches.

### 2. Payload shape

Today: full unmarshalled `NewImage`. Tomorrow: a fixed-shape descriptor.

```json
{
  "changeKind": "Added" | "Updated" | "Removed" | "BulkInvalidated",
  "id": "product-abc-123",
  "partitionKey": "dev-Shop",
  "sortKeyValue": "2026-05-19T10:32:00Z",   // optional — see §5
  "position": "1747641120000-uuid"           // optional — see §3
}
```

- **`changeKind`** — determines the client's reaction.
  - `Added`: NewImage exists, OldImage doesn't (INSERT events).
  - `Updated`: both present, different (MODIFY).
  - `Removed`: OldImage exists, NewImage doesn't (REMOVE). Today the Lambda skips REMOVE events — that must change.
  - `BulkInvalidated`: emitted by the OnPublish coalescer (§4), not the projector Lambda.
- **`id`** — the entity's primary key. Already accessible from `NewImage` or `OldImage` via the `@id` field.
- **`partitionKey`** — the partition this entity belongs to. Derived from the entity's `@compositeId` fields (the same fields that already form the projection partition key in single-entity queries, e.g. `pluginName/componentName`). The Lambda extracts these and joins them into a single string.
- **`sortKeyValue`** — value of the entity's natural sort field (typically `createdAt` or `updatedAt`). Lets paginated list clients classify Added events against the current page's sort range without fetching.
- **`position`** — DCB position of the source event that produced this change. See §3.

### 3. DCB position exposure (the upstream gap closed)

Projector handlers today receive the decoded event but not its DCB position (`StoredEvent.res:20` carries `position: string`). To populate `descriptor.position`, projector handlers must have access to the position when they apply the event.

Two implementation options:

**Option A: Pass position alongside the decoded event to the handler.**

Change the projector handler signature:

```rescript
// Today
type handler<'event, 'state> = ('event, 'state) => 'state

// New
type handler<'event, 'state> = (~event: 'event, ~state: 'state, ~position: string) => 'state
```

Most projectors don't need the position — they continue ignoring it. The handful that care (the AppSync Events publish path, future audit/replay tooling) can read it.

**Option B: Capture position in the projector wrapper, not the handler.**

The framework's projection-runner already iterates events; it has the position in scope before calling the handler. Have the wrapper pass `position` to the publish call directly (skipping the handler), bypassing the API surface change:

```rescript
// in the projector runner
events->Array.forEach(({position, event}) => {
  let nextState = handler(event, currentState)
  saveToDb(nextState)
  // NEW — pass position to whichever publish hook is registered
  publishHook->Option.forEach(p => p(~partitionKey, ~id, ~position, ~prevState, ~nextState))
})
```

**Recommendation: Option B.** No breaking change to the handler signature. The publish hook is the only thing that needs the position, and it doesn't need to be user-facing.

Location: `reventless-core/src/components/Projection/` (exact file to confirm during implementation). The hook is registered via the existing `subscriptionInfraHook` in `Platform.res`.

If `position` is `null` (e.g. yoga in-memory mode where DCB positions aren't surfaced the same way), descriptors carry `position: null` and downstream dedup falls back to "process every delivery" — acceptable degradation.

### 4. OnPublish handler: coalescing and BulkInvalidated

The trailing-edge debouncer lives as the namespace's `OnPublish` handler — AppSync Events runs it per published event before fanout.

```javascript
// OnPublish handler for namespace "default"
// Per-namespace registry (in-memory; warm Lambda reuse acceptable):
//   partitionRate: Map<partitionKey, { count, windowStart }>
//   buffered: Map<partitionKey, descriptor[]>
//   quietTimers: Map<partitionKey, timeoutId>

export const onPublish = async (ctx) => {
  const desc = ctx.event;
  const partition = desc.partitionKey;

  // Already in a burst? Buffer and reset quiet timer.
  if (buffered.has(partition)) {
    buffered.get(partition).push(desc);
    clearTimeout(quietTimers.get(partition));
    quietTimers.set(partition, setTimeout(() => emitBulkInvalidated(partition), 300));
    return null;  // suppress this delivery
  }

  // Track rate; if over threshold, start buffering.
  bumpRate(partition);
  if (rateOver(partition, 20, 300)) {
    buffered.set(partition, [desc]);
    quietTimers.set(partition, setTimeout(() => emitBulkInvalidated(partition), 300));
    return null;  // suppress this delivery
  }

  // Per-entity coalescing — drop if another descriptor for same id was sent within 200ms
  if (recentlyEmitted(partition, desc.id, 200)) return null;
  noteEmit(partition, desc.id);
  return desc;  // allow delivery
};

function emitBulkInvalidated(partition) {
  // Publish to {readModel}/{partition}/_meta with changeKind: BulkInvalidated
  publishToMetaChannel(partition, { changeKind: "BulkInvalidated", partitionKey: partition });
  buffered.delete(partition);
  quietTimers.delete(partition);
}
```

The handler runs on AWS-managed compute attached to the namespace; no separate Lambda. State is per-Lambda-instance (warm reuse is fine; cold start loses the buffered window — acceptable, results in a few stray individual descriptors instead of a coalesced bulk).

Tunable: rate threshold (20 events / 300ms), quiet window (300ms), per-entity dedup window (200ms). Defaults shipped; per-deployment overrides via namespace config.

### 5. `sortKeyValue` and pagination support

To support paginated list views without subscribing to the wrong rows, the descriptor includes the entity's value for the *natural sort field* — usually `createdAt` or `updatedAt` (whichever the projection's `@sortKey` annotation or schema generator picks).

The Lambda derives this from `NewImage` (or `OldImage` for `Removed` events) using the read model's known sort-field name. If a client renders data sorted by a different field, the descriptor still carries only the natural sort value; the client falls back to refetching the page for non-natural sort orders. A future optimisation (sort-aware subscriptions where the active sort field is part of the channel scope) is possible but out of scope for this plan.

### 6. Batched-by-id query

```graphql
Plugin_FooItemsByIds(ids: [String!]!): [Plugin_FooItem]
```

Implementation: per-read-model resolver with a BatchGetItem against the QueryDb's DynamoDB table. Generated by the AppSync resolver template generator alongside the existing single-entity query. Schema generator emits the field; runtime template uses the standard batch-get JS resolver pattern.

### 7. Resolving the `Sec-WebSocket-Protocol` blocker (resolved)

Phase 4 verification was blocked: all client `Sec-WebSocket-Protocol` formats returned `SubProtocolNotSupportedError`. Verified against the deployed `DomainEventsApi` on the `alpha` stack (eu-west-1) by intercepting the `aws-amplify` v6 client's WebSocket handshake, then replaying it with the built-in Node 22 `WebSocket`.

**URL.** The realtime endpoint host swaps `appsync-api` → `appsync-realtime-api`, path is `/event/realtime`:

```
wss://<host>.appsync-realtime-api.<region>.amazonaws.com/event/realtime
```

**`Sec-WebSocket-Protocol` is an array of TWO subprotocol strings**:

```
["aws-appsync-event-ws", "header-<base64>"]
```

The first identifies the AppSync Events real-time protocol. The second carries a base64-encoded JSON blob with the connection-level auth headers. For AWS_IAM auth the decoded JSON looks like:

```json
{
  "accept": "application/json, text/javascript",
  "content-encoding": "amz-1.0",
  "content-type": "application/json; charset=UTF-8",
  "host": "<host>.appsync-api.<region>.amazonaws.com",
  "x-amz-date": "20260519T111635Z",
  "authorization": "AWS4-HMAC-SHA256 Credential=<AKID>/<yyyymmdd>/<region>/appsync/aws4_request, SignedHeaders=accept;content-encoding;content-type;host;x-amz-date, Signature=<sigv4-hex>"
}
```

Notes:

- `host` inside the JSON is the **HTTPS** host (`appsync-api`), not the realtime host. AppSync signs the connection request as if it were a POST to the HTTPS endpoint.
- The SigV4 signature is short-lived (~5 minutes); long-lived connections re-auth at the per-subscribe layer.
- For API_KEY auth (not exercised — `DomainEventsApi` only allows `AWS_IAM`) the decoded JSON would carry `x-api-key` + `host` instead of SigV4 fields.

After the WebSocket opens, send `{"type":"connection_init"}` and wait for `{"type":"connection_ack","connectionTimeoutMs":<ms>}` before issuing `subscribe` messages.

To reproduce: monkey-patch Node 22's `globalThis.WebSocket` before importing `aws-amplify`, call `events.connect()`, log the constructor's `url` + `protocols` args. The captured `protocols` array can then be passed to a plain `new WebSocket(url, protocols)` to validate end-to-end without Amplify.

### 8. `OnSubscribe` handler hook (for tenant isolation)

The framework provides an extension point in `Platform.res` — `subscribeAuthHook: option<(channel: string, identity: identity) => result<unit, string>>` — that downstream extensions (e.g. the commercial multi-tenancy extension) can install to gate subscriptions.

```rescript
// Default: no hook, all subscribes allowed (open-core single-tenant case)
let subscribeAuthHook: option<...> = None

// Extension can install:
let subscribeAuthHook = Some((channel, identity) => {
  let partition = parseChannel(channel).segments[0]
  let allowedPartitions = identity.claims["allowedPartitions"]
  if Array.includes(allowedPartitions, partition) { Ok() } else { Error("tenant scope violation") }
})
```

The hook signature is in the core; no default implementation. The framework only enforces the hook is called for every subscribe; what it does is the extension's concern.

---

## Phases

### Phase 1: Channel layout migration ✅

Shipped as a 2-segment layout `{readModelName}/{entityKey}` — partitioning is deferred (see §1 above for the conceptual 3-segment design that Phases 2+ may reintroduce once `@compositeId` metadata is plumbed).

`StateTopic_AppSync.res` Lambda handler now:

- Extracts `entityKey` from `record.dynamodb.Keys` rather than schema metadata. The framework's `QueryDbStorage_DynamoDb` always names the partition-key attribute `"id"`; composite tables also have one sort-key attribute whose name comes from `subIdConfig.subIdField`. The handler reads both directly: single-key → `id`; composite → `{id}-{subIdValue}`. No deploy-time plumbing of field names needed.
- Channel = `/default/{topicRoot}/{entityKey}` with `_` → `-` normalisation applied to both segments.
- Processes all event types: `INSERT` / `MODIFY` use `NewImage`; `REMOVE` falls back to `OldImage`. Payload format unchanged (full row state) — descriptor reshape is Phase 2.

`Plugin_SubscriptionSchema.res`: `sourceBFields` removed and `generate` no longer takes `queryEntries` — Source B fans out via the AppSync Events WebSocket directly. Source A and Source C SDL emission unchanged.

AWS `Platform.res`: the `noneDs` + `makeSubscriptionResolver` block under the StateTopic loop is gone; `StateTopic_AppSync.make` is the only thing wired per stream-enabled QueryDb.

In-memory `Platform.res`: `bridgeSourceB` and the `sourceBEntries` loop dropped from the wiring. `bridgeSourceB` / `sourceBTopic` and the corresponding unit test remain as library helpers — Phase 8 will replace them with descriptor-shape publishing on a channel mirroring the AWS layout.

**Checklist:**

- [x] Lambda handler derives entity key from `record.Keys` (covers INSERT/MODIFY/REMOVE in one path)
- [x] Lambda publishes to `{readModelName}/{entityKey}` (underscores normalised to hyphens)
- [x] Lambda handles `REMOVE` events
- [x] `Plugin_SubscriptionSchema` drops Source B SDL fields
- [ ] Integration test: write to DynamoDB → verify Lambda publishes to correct channel — deferred (needs deployed stack; unit-level coverage of the entity-key derivation is a follow-up)
- [x] Build clean (1358 tests pass)

**Deviation from original design.** The plan's 3-segment `{rm}/{partition}/{id}` channel is not shipped in Phase 1; the partition concept is deferred until a projection's natural partition (`@compositeId` leading fields, multi-tenant scope, etc.) is plumbed through to the Lambda. List-view clients today get `{rm}/*`; partition-scoped subscriptions like `{rm}/{tenant}/*` are revisitable once the metadata story is decided.

### Phase 2: Change-descriptor payload ✅

The Lambda now publishes a change descriptor instead of the full row:

```json
{ "changeKind": "Added" | "Updated" | "Removed",
  "id":         "<entityKey>",
  "sortKeyValue"?: "<updatedAt | createdAt>" }
```

- `changeKind` maps from DDB stream `eventName`: `INSERT → Added`, `MODIFY → Updated`, `REMOVE → Removed`.
- `id` reuses the Phase 1 `entityKey` (DDB primary-key value, joined for composite tables).
- `sortKeyValue` is auto-discovered: `updatedAt` first, falling back to `createdAt`, omitted if neither field exists in the image. Hardcoded for now — making the field name configurable is a follow-up if a projection ever needs a different timestamp.
- `partitionKey` and `position` are intentionally omitted (Phase 1 deferred partitioning; Phase 3 will add `position`).

**Checklist:**

- [x] Lambda handler builds descriptor (`changeKind`, `id`, `sortKeyValue`); `partitionKey` deferred per Phase 1
- [x] `sortKeyValue` derived from natural sort field (default `updatedAt` → `createdAt` → unset)
- [x] Existing `on{Type}_stateChanged` clients removed in Phase 1 (no remaining consumers in this repo)
- [ ] Integration test verifies descriptor shape — deferred (needs deployed stack; Phase 1 deferred the same checklist item)
- [x] Build clean

### Phase 3: DCB position exposure 🟡 deferred

The plan's §3 Option B was based on a misread of the publish chain: the publish hook in this codebase is the `StateTopic_AppSync` Lambda, which is triggered by **DynamoDB Streams**, not invoked directly from the projector. The two Lambdas only exchange data via the DDB row itself. So "expose position to the publish hook" really means **persist position into the DDB row** so the stream carries it forward.

Concrete plumbing required (not done):

1. `ReadModel_Callback.res` — extract `position` from each decoded message (currently only `context` is decoded).
2. `Projection.res` — thread `~position` through `handleAction`, `handleActions`, and the `save`/`saveBatch`/`delete`/`deleteBatch` calls.
3. `QueryDb_Operations.res` (core) and every storage adapter (`QueryDbStorage_DynamoDb`, `QueryDbStorage_InMemory`, `QueryDbStorage_Sqlite`) — accept `~position` and persist a reserved attribute alongside the user state.
4. `StateTopic_AppSync.res` Lambda — read the reserved attribute from `NewImage`/`OldImage` and add `position` to the descriptor.
5. State-read paths — filter the reserved attribute out so downstream callers don't see it as a domain field.

This is the largest single phase by file count and touches every storage adapter. Deferred until a concrete consumer needs position-based dedup. The Phase 2 descriptor simply omits `position` for now.

**Checklist:** (deferred)

### Phase 4: OnPublish handler with coalescing 🟡 deferred

The plan's §4 coalescer requires **state that persists across published events** (the `partitionRate` / `buffered` / `quietTimers` maps). AppSync Events' pure `APPSYNC_JS` runtime is stateless per invocation, so persistent state means the OnPublish handler must be backed by a Lambda data source (`handlerConfigs.onPublish` with `lambdaConfig`) and rely on Lambda warm-instance reuse.

That requires a new Lambda + AppSync Lambda data source + namespace `handlerConfigs` wiring + the coalescer state machine + unit tests. Substantial infrastructure work whose value materialises only once real WebSocket clients are observing burst traffic. Deferred until subscriber load actually demands it; the Phase 1+2 fanout cost is acceptable for current load.

Also note: Phase 1 deferred partitioning, so the per-partition coalescing pieces (`BulkInvalidated`, partition rate) collapse to per-read-model when Phase 4 reopens.

**Checklist:** (deferred)

### Phase 5: Batched-by-id query ✅

Each single-key projection now emits `${listFieldName}ByIds(ids: [String!]!): [${returnTypeName}!]!` alongside the existing single-byId / list / items / by-index fields.

Naming: the plan's placeholder `Plugin_FooItemsByIds` translates to `${listFieldName}ByIds` in this codebase — e.g. `catalog_ProductsByIds`, `Platform_PluginsByIds`. The plural list-name root keeps the field discoverable next to the existing list query.

Return-type semantics: `[returnTypeName!]!`. BatchGetItem does not preserve cardinality (missing ids drop out), so callers correlate by `id` on each returned item. Empty input short-circuits to `[]` without hitting DDB (`runtime.earlyReturn([])`).

Composite-key projections (`subIdField=Some(...)`) are deliberately skipped — DynamoDB's BatchGetItem requires both partition + sort attributes per key entry, and the field would need a richer `ids: [SomeKeyInput!]!` shape (out of scope).

Implementation:
- `GraphQL_FragmentGenerator.res` — new `deriveByIdsQueryField` plus a guarded `queries->Array.push` inside the queryEntries loop (only when `includeIdParam && subIdField === None`).
- `rescript-pulumi-aws/AppSync_Resolver_Functions.res` — new `batchGetItemsByIds(tableName)` JS resolver template (`BatchGetItem` with the table name interpolated at deploy time, since BatchGetItem's `tables` map keys on the literal name).
- `QueryDbResolvers_AppSync.res` — wires the resolver via the existing `storageResource`/`generateCode` helpers and appends it to the main resolver array.
- `QueryDbResolvers_GraphQL.res` (in-memory) — adds a matching SDL field (via `deriveByIdsQueryField` for SDL parity) and a resolver that loops over `ops.loadStream(id)`, dropping missing ids and injecting the `id` field for Relay Node compatibility.

**Checklist:**

- [x] Schema generator emits the batch-by-ids field (single-key projections only)
- [x] AppSync BatchGetItem resolver template
- [x] In-memory adapter matches the resolver shape (uses the same SDL helper for parity)
- [ ] Integration test for both prod and dev adapters — deferred (an in-memory unit test for the resolver would round out coverage; deployed integration test requires AWS access)
- [x] Build clean (1358 tests pass; existing `GraphQL_SchemaInspectorTest` query count bumped 2 → 3 to account for the new field)

### Phase 6: Resolve `Sec-WebSocket-Protocol` ✅

Investigation + verification, not a code change to core itself. Verified 2026-05-19 against the `alpha` stack `DomainEventsApi` in eu-west-1. See §7 for the documented format.

**Checklist:**

- [x] Capture working Amplify Events client WebSocket handshake (via Node 22 `globalThis.WebSocket` monkey-patch — `capture-handshake.mjs`)
- [x] Document the exact `Sec-WebSocket-Protocol` value and any base64-encoded auth payload format
- [x] Add documented format to this plan (§7)
- [x] Smoke test: built-in `WebSocket` connects with the captured protocols and receives `connection_ack` — `smoke-test.mjs`

### Phase 7: `OnSubscribe` hook ✅

Wired as a registry on `AppSync_EventsApi.res` rather than as a callback field on `Platform.res` — closer to the resource that consumes it, and matches the existing `onPluginDeployedHook` pattern in `Plugin_Helpers.res`. The hook surface is intentionally minimal: downstream extensions install JS code + a data source name, the framework wires the namespace's `handlerConfigs.onSubscribe` to call it.

Concrete API ([`AppSync_EventsApi.res`](../../reventless/reventless-aws/src/adapter/Api/AppSync_EventsApi.res)):

```rescript
type subscribeAuthConfig = {
  codeHandlers: string,                          // exports onSubscribe(ctx)
  dataSourceName: Pulumi.Input.t<string>,        // NONE-typed DS on the Events API
}

let registerSubscribeAuth: subscribeAuthConfig => unit
let clearSubscribeAuth: unit => unit
```

The extension calls `registerSubscribeAuth` before platform construction. The framework reads the registry inside `AppSync_EventsApi.make` and forwards both fields to the underlying `ChannelNamespace`. No call ⇒ namespace falls back to API-level auth modes (single-tenant open-core default).

This phase also extended the `rescript-pulumi-aws` ReScript binding for `ChannelNamespace` with the previously-missing `codeHandlers` / `handlerConfigs` fields plus the supporting types (`handlerConfigsArgs`, `handlerConfigArgs`, `integrationArgs`, `lambdaConfigArgs`) and `handlerBehavior` / `invokeType` string constants. The binding now matches AWS's CloudFormation surface for the resource.

**Checklist:**

- [x] `subscribeAuthConfig` type + `registerSubscribeAuth` / `clearSubscribeAuth` registry on `AppSync_EventsApi.res`
- [x] Wired into `AppSync_EventsApi.make` namespace provisioning via the new `codeHandlers` / `handlerConfigs` fields
- [x] Documented hook contract in the `AppSync_EventsApi.res` file header
- [x] No default implementation (`subscribeAuthRef = ref(None)`; single-tenant deploys are unaffected)
- [x] `rescript-pulumi-aws` `ChannelNamespace` binding extended with the missing CloudFormation fields
- [x] Build clean (1358 tests pass)

### Phase 8: In-memory parity ✅

`InMemory_Bus.publishStateChange` now carries the **change descriptor** rather than the full row state — dev clients consuming the bridge see the same JSON shape as AWS WebSocket subscribers.

Concrete changes:

- `InMemory_Bus.res` — `publishStateChange` parameter renamed `~state` → `~descriptor`; new module-level helper `makeStateChangeDescriptor(~changeKind, ~id, ~state)` produces the `{changeKind, id, sortKeyValue?}` payload (same `updatedAt → createdAt → omit` rule as the AWS Lambda).
- `QueryDbStorage_InMemory.res` and `QueryDbStorage_Sqlite.res` — every `save`/`saveBatch`/`delete`/`deleteBatch` now builds a descriptor and publishes it. Entity key follows the AWS rule: single-key tables → partition value, composite tables → `pk-sk`. `delete`/`deleteBatch` now publish `"Removed"` descriptors (previously silent — fixed gap relative to AWS).
- `GraphQL_SubscriptionResolversTest.res` — both Source B tests updated to assert the descriptor shape.

**Documented dev/prod divergence:**
- `changeKind` is `"Updated"` for save() in dev — the in-memory storage doesn't cheaply distinguish first-insert from update; AWS uses DDB streams' INSERT vs MODIFY for this. `"Removed"` is emitted on delete in both.
- `position` is omitted in both dev and prod (Phase 3 deferred).
- OnPublish coalescer omitted in dev (Phase 4 deferred; dev gets every change raw, which is fine at dev scale).
- Channel-name parity is not implemented — the in-memory bus is keyed by read-model name and pubsub topic, not channel paths. Subscribers that need per-entity filtering must filter on `descriptor.id` themselves. Full channel parity would require a layered pubsub mirroring AppSync Events; out of scope.

**Checklist:**

- [x] `InMemory_Bus` publishes descriptors (not full state) on `publishStateChange`
- [ ] Channel name mirrors the AWS channel format — partial: payload mirrors AWS; topic/channel layering doesn't. Subscribers filter by `descriptor.id`.
- [x] OnPublish coalescer omitted in dev (Phase 4 deferred)
- [x] `position` omitted in dev (Phase 3 deferred; both AWS and dev consistent)
- [x] Existing tests in `tests/adapter/GraphQL_SubscriptionResolversTest.res` updated for descriptor shape
- [x] Build clean (1358 tests pass)

---

## File Map (estimated)

### Modified

| Package | File | Phase | Change |
|---|---|---|---|
| `reventless-aws` | `src/adapter/StateTopic/StateTopic_AppSync.res` | 1, 2, 3 | Channel + payload shape; REMOVE handling; position from projector |
| `reventless-core` | `src/components/Plugin/Plugin_SubscriptionSchema.res` | 1 | Drop Source B SDL fields (clients use Events directly) |
| `reventless-core` | `src/components/Projection/<projector-runner>.res` | 3 | Thread position through publish hook |
| `reventless-aws` | `src/adapter/Api/<batch-resolver>.res` | 5 | BatchGetItem-by-ids resolver template |
| `reventless-core` | `src/components/Api/GraphQL_FragmentGenerator.res` | 5 | Emit `Plugin_FooItemsByIds(...)` field |
| `reventless-core` | `src/Platform.res` | 7 | `subscribeAuthHook` hook surface |
| `reventless-in-memory` | `src/InMemory_Bus.res` | 8 | Descriptor-shape publish; channel format |

### New

| Package | File | Phase | Purpose |
|---|---|---|---|
| `reventless-aws` | `src/adapter/StateTopic/StateTopic_OnPublish_Handler.js` (inline string) | 4 | OnPublish coalescer for the Events namespace |
| `reventless-aws` | `tests/StateTopic_OnPublish_HandlerTest.res` | 4 | Coalescer state-machine unit tests |

---

## Open questions

1. **`@id` and `@compositeId` discoverability at deploy time.** `StateTopic_AppSync.make` needs the field names to compute partition + entity from `NewImage`. Confirm these are already in scope via QueryDb metadata or need to be passed explicitly.

2. **OnPublish handler runtime model.** AppSync Events OnPublish runs per published event; persistent state across invocations relies on Lambda warm reuse. Cold starts lose the buffered window. Acceptable for the trailing-edge case (worst case: a few stray individual descriptors before the next burst settles) but document the failure mode.

3. **In-memory adapter coalescer.** Whether dev should emulate coalescing or just publish raw. Simpler: publish raw in dev (every change becomes a descriptor), accept the dev/prod divergence. More complex: implement a small JS coalescer in `InMemory_Bus`. Recommend simpler unless dev gets confusing.

4. **Channel name length under composite IDs.** If `partitionKey` is `plugin-name/component-name` (URL-encoded `plugin-name%2Fcomponent-name`) and exceeds 50 chars, we need a hashing fallback. Confirm typical lengths in current deployments and pick a fallback rule.

---

## Dependencies

- Builds on: [graphql-subscriptions-appsync.md](graphql-subscriptions-appsync.md) Phases 1–4 (deployed and verified)
- Required by: nothing in core

---

## Out of scope

- Sync wait-for-projection mutations (would benefit from position-based dedup; can ship after this plan completes).
- Sort-aware subscriptions (re-subscribe when user changes sort field). Documented in client plan as future work.
- Source A (raw event stream) is unchanged; it serves a different audience (admin/observability) and its full-event payload remains appropriate.
- Source C (`@aws_subscribe` mutation-triggered) is unchanged; this plan only changes Source B (state-change push).
