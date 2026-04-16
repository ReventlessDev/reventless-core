# Plan: GraphQL Subscriptions — AppSync Real-Time Infrastructure

## Context and Motivation

Reventless platforms expose a GraphQL API through which clients issue commands and query read-model state. All of that is currently request/response: the client asks, the server answers. Clients have to poll to discover state changes.

GraphQL subscriptions eliminate polling by opening a persistent WebSocket connection and pushing updates the moment they become available. This plan covers the complete AppSync subscription infrastructure and its in-memory (yoga) counterpart for local development.

**Group F finding** (from plugin-hook-metadata-and-schema-extensions.md): Neither `AppSync_Resolver_Native.res` nor `AppSync_Resolver_Retrying.res` contains any `@aws_subscribe` or subscription resolver support. Both resolver builders only construct `Mutation` and `Query` type resolvers. Adding subscription resolver support is the first step here.

This plan supersedes [graphql-subscriptions-realtime.md](Backlog/graphql-subscriptions-realtime.md), preserving its architectural design (Sources A, B, C; AppSync Events API push) and adding concrete implementation steps, file maps, and checklists. That backlog plan is archived.

**Related plan**: [reventless-client-transport.md](Backlog/reventless-client-transport.md) covers the direct HTTP command endpoint and `pullEvents` catch-up query — client transport concerns that are independent of subscriptions.

---

## Scope

| Capability | AWS (production) | In-Memory (local dev) |
|-----------|------------------|-----------------------|
| `@aws_subscribe` mutation-triggered subscriptions (Source C) | AppSync resolver on `Subscription` type | yoga subscription via PubSub |
| State-change subscriptions — projected state pushed on QueryDb write (Source B) | DynamoDB Stream → Lambda → AppSync Events API | yoga subscription via PubSub |
| Raw event stream subscriptions (Source A) | SNS EventTopic → Lambda → AppSync Events API | yoga subscription via PubSub |

**Out of scope for this plan**: HTTP command endpoint (see `reventless-client-transport.md`). `pullEvents` catch-up query (see `reventless-client-transport.md`). The `reventless-client` library itself. API Gateway WebSocket bidirectional transport. Offline-first SQLite WASM bindings.

---

## Background: Three Subscription Sources

```
Source A — Raw domain events
  EventLog / DcbEventLog → SNS EventTopic → Lambda → AppSync Events API → Client WebSocket

Source B — Read model state changes
  QueryDb write → DynamoDB Stream → StateTopic Lambda → AppSync Events API → Client WebSocket

Source C — Mutation-triggered (zero extra infrastructure)
  AppSync Mutation resolves → @aws_subscribe built-in trigger → Client WebSocket
```

Source C is the cheapest to implement and fires when a command is *accepted* — before the resulting event is projected. Sources A and B fire after the event is fully processed. All three are useful for different patterns (see use cases in the backlog design doc).

---

## Prerequisite: GraphQL API Stitching

The `GraphqlSchema.fragment` type (defined in `reventless-spec`) currently has `types`, `queries`, and `mutations` fields. Subscriptions require a fourth field: `subscriptions: string`. This must be added first as it is the foundation for SDL generation.

The stitching plan ([graphql-api-stitching.md](Backlog/graphql-api-stitching.md)) covers the full multi-plugin merge pattern. For this plan's purposes, only the `subscriptions` field addition and the `type Subscription { }` merge step are required — the rest of stitching can land later.

---

## Phase 1 — Spec: `subscriptions` field and resolver type support

**Target packages**: `reventless-spec`, `rescript-pulumi-aws`, `reventless-aws`

### 1.1 Add `subscriptions` to `GraphqlSchema.fragment`

```rescript
// reventless-spec/src/components/GraphqlSchema.res
type fragment = {
  types: string,
  queries: string,
  mutations: string,
  subscriptions: string,  // NEW — bare fields for `type Subscription { ... }`
}
```

All existing `fragment` literals gain `subscriptions: ""` (backward-compatible empty string).

### 1.2 Add `subscriptionFilter` to AppSync resolver args

AppSync subscription resolvers support server-side filter expressions — only events matching the filter reach the subscriber. This is how per-entity subscriptions (e.g., `onOrderStatusChanged(orderId: "ord-7")`) work without server-side O(n) fanout.

```rescript
// rescript/rescript-pulumi-aws — add to Native resolver args:
subscriptionFilter?: Pulumi.Input.t<string>  // JSON-encoded enhanced filter expression
```

AppSync evaluates the filter per-event before delivery, using values from `ctx.args` on the subscription call.

### 1.3 Add `makeSubscriptionResolver` to AppSync resolver builders

Subscription resolvers live on the `Subscription` type and have different semantics from query/mutation resolvers — they require no data source. AppSync evaluates the filter and delivers the payload directly from the push event.

```rescript
// reventless-aws/src/adapter/Api/AppSync_Resolver_Native.res — add:
let makeSubscriptionResolver = (
  ~name,
  ~api,
  ~field,
  ~subscriptionFilter: option<string>=?,
  ~opts=?,
) =>
  Native.make(~name, ~args={
    apiId: api->Pulumi.Output.flatMap(a => a.id)->Pulumi.Output.asInput,
    typeName: "Subscription",
    fieldName: field,
    kind: "UNIT"->Pulumi.Input.make,
    code: makeSubscriptionResolverCode(~filter=subscriptionFilter)->Pulumi.Input.make,
    runtime: Native.appsyncJs->Pulumi.Input.make,
  }, ~opts)
```

The resolver code (AppSync JS):
- Request: `export function request(ctx) { ctx.extensions.setSubscriptionFilter(<filter>); return { payload: null }; }`
- Response: `export function response(ctx) { return ctx.result; }`

Add the same function to `AppSync_Resolver_Retrying.res` with the same retry pattern as its existing `make*` functions.

### 1.4 Steps

- [ ] Add `subscriptions: string` to `GraphqlSchema.fragment` in `reventless-spec`
- [ ] Add `subscriptions: ""` to all existing `fragment` literals in `reventless-core` and examples
- [ ] Add optional `subscriptionFilter` to `AppSync_Resolver_Native` resolver args binding in `rescript-pulumi-aws`
- [ ] Add `makeSubscriptionResolver` to `AppSync_Resolver_Native.res`
- [ ] Add `makeSubscriptionResolver` to `AppSync_Resolver_Retrying.res`
- [ ] Build: verify no regressions on existing resolver construction

---

## Phase 2 — SDL generation: subscription fragment per plugin

**Target packages**: `reventless-core`

### 2.1 `Plugin_SubscriptionSchema.res`

A new helper that generates the subscription SDL fragment for a plugin based on its components. Produces three categories:

**Source C — one per command type** (mutation-triggered):
```graphql
onCatalogProduct_AddProduct(id: ID!, name: String!, price: Float!): String
  @aws_subscribe(mutations: ["CatalogProduct_AddProduct"])
```
Generated from the command resolver field names (same naming convention as mutations). The return type is `String` — clients use this to confirm acceptance before the state-change subscription fires.

**Source B — one per StateViewSlice/ReadModel** with an `@id`-annotated state field:
```graphql
onCatalogProduct_stateChanged(id: ID): CatalogProduct
```
The `id` argument is optional. If provided, AppSync filters server-side. The payload type reuses the existing read model type. No `@aws_subscribe` — pushed via AppSync Events API.

**Source A — one per DcbEventLog/Aggregate EventLog** (admin-only):
```graphql
onCatalogEventLog_eventAppended: CatalogEventLogEvent
```
With supporting type:
```graphql
type CatalogEventLogEvent {
  position: String!
  eventType: String!
  payload: AWSJSON!
  originatorSlice: String
}
```
`originatorSlice` is populated from the DCB event tag added by `StateChangeSlice_Callback.encodeEvent` (Group D of plugin-hook-metadata-and-schema-extensions.md).

### 2.2 SDL stitcher subscription merge

Extend `GraphqlSchemaStitcher.stitch` to merge all plugin `subscriptions` fragments into a single `type Subscription { }` block in the final SDL, alongside the existing Query/Mutation merge.

### 2.3 Steps

- [ ] Create `reventless-core/src/components/Plugin/Plugin_SubscriptionSchema.res`
- [ ] Generate Source C fields from command resolver field names
- [ ] Generate Source B fields from StateViewSlice/ReadModel specs (derive filter arg name from `@id` field)
- [ ] Generate Source A fields from DcbEventLog/Aggregate EventLog presence
- [ ] Populate `fragment.subscriptions` in `Plugin_Builder.res` alongside `fragment.mutations`/`fragment.queries`
- [ ] Extend `GraphqlSchemaStitcher.stitch` to emit `type Subscription { <merged> }` when any fields exist
- [ ] Build clean

---

## Phase 3 — Source C: Mutation-triggered subscriptions

**Target packages**: `reventless-aws`

### 3.1 `CommandSubscriptionResolvers_AppSync.res`

Creates one AppSync `Subscription` type resolver per command mutation field using `makeSubscriptionResolver` from Phase 1. No data source needed — AppSync delivers the mutation's return value to all subscribers automatically.

The SDL `@aws_subscribe(mutations: ["X"])` directive is emitted by Phase 2's SDL generator. The Pulumi resolver resource registers the resolver handler for the `Subscription.onX` field.

### 3.2 Steps

- [ ] Create `reventless-aws/src/adapter/Api/CommandSubscriptionResolvers_AppSync.res`
- [ ] For each command mutation field `X`, create `Subscription.onX` resolver
- [ ] Wire into `Core_AppSync_Builder.res` after mutation resolvers are created
- [ ] Deploy and verify subscription fields appear in AppSync schema

---

## Phase 4 — Source B: State-change subscriptions (QueryDb → AppSync Events API)

**Target packages**: `reventless-aws`

### 4.1 Architecture

```
QueryDb (DynamoDB) ── DynamoDB Stream ──► StateTopic Lambda ──► AppSync Events HTTP API ──► Client WebSocket
```

Each `QueryDb` (ReadModel or StateViewSlice) gets a DynamoDB Stream enabled. A Lambda subscribes to the stream and pushes changed items to AppSync via the Events HTTP API.

### 4.2 `StateTopic_AppSync.res`

**Deploy-time resources**:
- Enable DynamoDB Streams on the QueryDb table (`streamViewType: "NEW_IMAGE"`)
- Lambda function: receives DynamoDB Stream records, maps `NewImage` to state payload, calls AppSync Events API
- IAM: Lambda execution role with `appsync:GraphQL` on the specific API ARN
- `aws.lambda.EventSourceMapping`: DynamoDB Stream → Lambda trigger

**Runtime (Lambda handler)**:
```javascript
export async function handler(event) {
  for (const record of event.Records) {
    if (record.eventName === "REMOVE") continue;
    const newImage = unmarshall(record.dynamodb.NewImage);
    await appsync.publishEvent({
      channel: `/default/${topicName}`,
      events: [JSON.stringify(newImage)],
    });
  }
}
```

### 4.3 Subscription filter

The Phase 2 SDL generator emits the filter on the subscription resolver using the `@id` field name. Phase 1's `subscriptionFilter` arg passes it to `makeSubscriptionResolver`:

```json
{
  "filterGroup": [{
    "filters": [{ "fieldName": "productId", "operator": "eq", "value": { "ref": "ctx.args.id" } }]
  }]
}
```

### 4.4 Steps

- [ ] Create `reventless-aws/src/adapter/StateTopic/StateTopic_AppSync.res` (deploy-time resources)
- [ ] Create `StateTopic_AppSync_Handler.res` (or `.mjs`) — Lambda runtime: DynamoDB Stream → AppSync Events API
- [ ] Add optional `~streamEnabled` flag to `QueryDbStorage_DynamoDb.res`
- [ ] Wire `StateTopic_AppSync` into `Core_AppSync_Builder.res` for each ReadModel/StateViewSlice with subscriptions
- [ ] Set `subscriptionFilter` on matching subscription resolver
- [ ] Verify: state change → push reaches WebSocket subscriber

---

## Phase 5 — Source A: Raw event stream subscriptions (SNS → AppSync Events API)

**Target packages**: `reventless-aws`

### 5.1 Architecture

```
EventTopic (SNS) ──► SQS buffer ──► EventLogSubscription Lambda ──► AppSync Events HTTP API ──► Client WebSocket
```

Each plugin's EventTopic (SNS) triggers a Lambda that pushes raw events to AppSync. Admin-only — exposes the full domain event stream for observability.

### 5.2 `EventLogSubscription_AppSync.res`

**Deploy-time resources** (reuses existing SQS/SNS patterns from `EventCollectorChannel_DynamoDbStream`):
- SQS queue (buffering + dead-letter)
- SNS → SQS subscription (`Util_SQS.subscribeToSnsTopic`)
- Lambda function: maps `{position, eventType, data, tags}` to AppSync Events API payload
- IAM: `appsync:GraphQL` permission on specific API ARN
- `aws.lambda.EventSourceMapping`: SQS → Lambda trigger

**Runtime (Lambda handler)**:
```javascript
export async function handler(event) {
  for (const record of event.Records) {
    const body = JSON.parse(record.body);
    const originatorSlice = body.tags?.find(t => t.key === "originatorSlice")?.value;
    await appsync.publishEvent({
      channel: `/default/${topicName}`,
      events: [JSON.stringify({
        position: body.position,
        eventType: body.eventType,
        payload: body.data,
        originatorSlice,
      })],
    });
  }
}
```

### 5.3 Steps

- [ ] Create `reventless-aws/src/adapter/EventLogSubscription/EventLogSubscription_AppSync.res` (deploy-time resources)
- [ ] Create runtime Lambda handler: SNS event → AppSync Events API push
- [ ] Wire into `Core_AppSync_Builder.res` for DcbEventLog and Aggregate EventTopics
- [ ] Verify: domain event → push reaches admin WebSocket subscriber with `originatorSlice` populated

---

## Phase 6 — In-memory WebSocket subscriptions

**Target packages**: `reventless-in-memory`

### 6.1 Motivation

The local dev experience must mirror production so client code works unchanged between environments. graphql-yoga v5 supports GraphQL subscriptions natively via `createPubSub` and the `graphql-ws` protocol (matching AppSync's WebSocket subscription protocol).

### 6.2 `InMemory_Bus` PubSub extension

Add a `PubSub` instance to the bus and publish to it whenever `publishEvent` fires. The topic name mirrors the AppSync subscription field name convention:

```rescript
// Extension to InMemory_Bus
let pubSub = createPubSub()  // yoga/graphql-yoga createPubSub

let publishEvent = (bus, event) => {
  // existing: fan-out to read model handlers
  bus.subscribers->Array.forEach(sub => sub(event))
  // new: publish to PubSub for WebSocket subscribers
  let topicName = deriveTopicName(event)
  pubSub->publish(topicName, event)
}
```

### 6.3 `GraphQL_SubscriptionResolvers_InMemory.res`

Registers yoga subscription resolvers that subscribe to the PubSub and yield events to WebSocket clients:

```rescript
let register = (server, bus, ~subscriptionFields: array<string>) => {
  subscriptionFields->Array.forEach(field => {
    server->registerSubscriptionResolver(field, {
      subscribe: (_root, args) => bus->subscribeToEventAsyncIterator(field, args),
      resolve: event => event,
    })
  })
}
```

### 6.4 Steps

- [ ] Add `PubSub` instance to `InMemory_Bus` (using yoga `createPubSub`)
- [ ] Extend `InMemory_Bus.publishEvent` to also publish to PubSub
- [ ] Create `reventless-in-memory/src/adapter/Api/GraphQL_SubscriptionResolvers_InMemory.res`
- [ ] Wire into `Platform_InMemory.res` alongside existing yoga query/mutation resolvers
- [ ] Integration test: browser/test client receives events via WebSocket from in-memory backend

---

## File Map

### New files

| Package | File | Phase | Purpose |
|---------|------|-------|---------|
| `reventless-core` | `src/components/Plugin/Plugin_SubscriptionSchema.res` | 2 | Subscription SDL fragment generator |
| `reventless-aws` | `src/adapter/Api/CommandSubscriptionResolvers_AppSync.res` | 3 | Source C: mutation-triggered subscription resolvers |
| `reventless-aws` | `src/adapter/StateTopic/StateTopic_AppSync.res` | 4 | Source B: DynamoDB Stream → AppSync Events API |
| `reventless-aws` | `src/adapter/StateTopic/StateTopic_AppSync_Handler.res` | 4 | Source B: Lambda runtime handler |
| `reventless-aws` | `src/adapter/EventLogSubscription/EventLogSubscription_AppSync.res` | 5 | Source A: SNS → AppSync Events API |
| `reventless-in-memory` | `src/adapter/Api/GraphQL_SubscriptionResolvers_InMemory.res` | 6 | WebSocket subscriptions for yoga |

### Modified files

| Package | File | Phase | Change |
|---------|------|-------|--------|
| `reventless-spec` | `src/components/GraphqlSchema.res` | 1 | Add `subscriptions: string` to `fragment` |
| `rescript-pulumi-aws` | `src/AppSync/AppSync_Resolver.res` (bindings) | 1 | Add optional `subscriptionFilter` to args |
| `reventless-aws` | `src/adapter/Api/AppSync_Resolver_Native.res` | 1 | Add `makeSubscriptionResolver` |
| `reventless-aws` | `src/adapter/Api/AppSync_Resolver_Retrying.res` | 1 | Add `makeSubscriptionResolver` |
| `reventless-core` | `src/components/Plugin/Plugin_Builder.res` | 2 | Populate `fragment.subscriptions` |
| `reventless-core` | `src/core/GraphqlSchemaStitcher.res` | 2 | Merge subscription fragments into `type Subscription { }` |
| `reventless-aws` | `src/adapter/QueryDb/QueryDbStorage_DynamoDb.res` | 4 | Add optional `~streamEnabled` flag |
| `reventless-aws` | `src/core/Core_AppSync_Builder.res` | 3, 4, 5 | Wire all subscription publishers and resolvers |
| `reventless-in-memory` | `src/InMemory_Bus.res` | 6 | Add PubSub + `publishEvent` PubSub fanout |
| `reventless-in-memory` | `src/Platform.res` | 6 | Wire subscription resolvers into yoga server |

---

## Subscription SDL: Full example (Catalog plugin)

```graphql
type Subscription {

  # Source C — fires when command is ACCEPTED (mutation-triggered, instant)
  onCatalogProduct_AddProduct(id: ID!, name: String!, price: Float!, categoryId: ID!): String
    @aws_subscribe(mutations: ["CatalogProduct_AddProduct"])
    @aws_auth(cognito_groups: ["Admin"])

  onCatalogProduct_ChangeProductPrice(id: ID!, price: Float!): String
    @aws_subscribe(mutations: ["CatalogProduct_ChangeProductPrice"])
    @aws_auth(cognito_groups: ["Admin"])

  # Source B — fires when READ MODEL STATE CHANGES (after event is projected)
  onCatalogProduct_stateChanged(id: ID): CatalogProduct
    @aws_auth(cognito_groups: ["User", "Admin"])

  onCatalogCategory_stateChanged(id: ID): CatalogCategory
    @aws_auth(cognito_groups: ["User", "Admin"])

  # Source A — raw event stream (admin/observability only)
  onCatalogEventLog_eventAppended: CatalogEventLogEvent
    @aws_auth(cognito_groups: ["Admin"])
}

type CatalogEventLogEvent {
  position: String!
  eventType: String!
  payload: AWSJSON!
  originatorSlice: String
}
```

---

## Dependency Order

```
Phase 1 (spec + resolver builders)
    ↓
Phase 2 (SDL generation)
    ↓
Phase 3 (Source C) ─┐
Phase 4 (Source B) ─┤── all independent, can run in parallel
Phase 5 (Source A) ─┘
Phase 6 (in-memory WebSocket) — independent of Phases 3–5
```

---

## Open Questions

1. **AppSync Events API auth**: The push Lambda needs `appsync:GraphQL` permission. Scope to specific API ARN (recommended) or to `arn:aws:appsync:*:*:apis/*` (simpler)?

2. **Source B payload — full state vs. delta**: DynamoDB Stream Lambda pushes full `NewImage` (recommended — simpler for client, bounded by state schema size) or just changed fields (more efficient)?

3. **In-memory WebSocket protocol**: `graphql-ws` (matches AppSync protocol, recommended) or SSE (simpler but different from production)?

4. **Source A auth**: Should the raw event stream subscription (`onCatalogEventLog_eventAppended`) be opt-in per plugin, or generated for all plugins and restricted by `@aws_auth`?

---

## Checklist

### Phase 1 — Spec and resolver builders
- [ ] `subscriptions: string` in `GraphqlSchema.fragment`
- [ ] `subscriptions: ""` backfilled in all existing `fragment` literals
- [ ] `subscriptionFilter` in `AppSync_Resolver_Native` args binding
- [ ] `makeSubscriptionResolver` in `AppSync_Resolver_Native.res`
- [ ] `makeSubscriptionResolver` in `AppSync_Resolver_Retrying.res`
- [ ] Build clean

### Phase 2 — SDL generation
- [ ] `Plugin_SubscriptionSchema.res` created
- [ ] Source C fields generated (one per command mutation field)
- [ ] Source B fields generated (one per StateViewSlice/ReadModel with `@id` state)
- [ ] Source A fields generated (per EventLog/DcbEventLog)
- [ ] `fragment.subscriptions` populated in `Plugin_Builder.res`
- [ ] `GraphqlSchemaStitcher.stitch` emits `type Subscription { }`
- [ ] Build clean

### Phase 3 — Source C (mutation-triggered)
- [ ] `CommandSubscriptionResolvers_AppSync.res` created
- [ ] One subscription resolver per command field
- [ ] Wired into `Core_AppSync_Builder.res`
- [ ] Verified in deployed AppSync schema

### Phase 4 — Source B (state-change push)
- [ ] `StateTopic_AppSync.res` created (DynamoDB Streams + Lambda + IAM + EventSourceMapping)
- [ ] Runtime handler calls AppSync Events API
- [ ] `QueryDbStorage_DynamoDb.res` streams opt-in flag added
- [ ] Subscription filter wired from state `@id` field name
- [ ] Verified: state change → push reaches WebSocket subscriber

### Phase 5 — Source A (raw event stream)
- [ ] `EventLogSubscription_AppSync.res` created (SNS → SQS → Lambda → AppSync)
- [ ] Runtime handler maps event envelope to subscription payload
- [ ] `originatorSlice` tag included in payload
- [ ] Verified: domain event → push reaches admin WebSocket subscriber

### Phase 6 — In-memory WebSocket
- [ ] `InMemory_Bus` PubSub added
- [ ] `publishEvent` also publishes to PubSub
- [ ] `GraphQL_SubscriptionResolvers_InMemory.res` created
- [ ] Wired into `Platform_InMemory.res`
- [ ] Integration test: test client receives events via WebSocket from in-memory backend
