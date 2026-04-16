# Plan: GraphQL Subscriptions for Real-Time Client Updates

## Motivation

Reventless platforms expose a GraphQL API through which clients — particularly user interfaces — issue commands and query read-model state. Today all of that is request/response: the client asks, the server answers. But event-sourced systems are inherently asynchronous and reactive. A command is submitted, events are appended, projections are updated, and eventually the read model reflects the new state. Clients have to poll to discover those changes.

GraphQL subscriptions eliminate polling by opening a persistent connection (WebSocket) and pushing updates to clients the moment they become available. This section motivates the feature with concrete use cases before describing how it fits into the framework.

---

## Use Cases

### 1. Live Order Status Tracking

A customer places an order through an e-commerce platform. After submitting the order, the UI shows a status page: *"Awaiting payment → Payment confirmed → Picking → Shipped → Delivered"*. Today the UI must poll the `Order` query every few seconds to detect state transitions. With a subscription:

```graphql
subscription {
  onOrderingOrder_stateChanged(id: "order-42") {
    id
    status
    estimatedDelivery
    lastUpdatedAt
  }
}
```

The UI receives a push the instant the `OrderingOrder` StateViewSlice projection processes the next domain event. No polling, no delay, no wasted requests. The subscription is keyed by order ID so only the relevant subscriber is notified.

**Event source**: `StateViewSlice` → QueryDb DynamoDB Stream → subscription push.

---

### 2. Live Inventory Dashboard

A warehouse management UI shows stock levels for hundreds of SKUs. Operators need to see quantities update in real time as items arrive or leave. A REST/GraphQL polling approach would require high-frequency queries for each SKU. With subscriptions:

```graphql
subscription {
  onInventoryStock_stateChanged(sku: "WIDGET-7") {
    sku
    quantityOnHand
    reservedQuantity
    lastMovementAt
  }
}
```

The DcbEventLog captures all inventory events. StateViewSlice projections maintain per-SKU stock state. When a `StockReceived` or `StockShipped` event commits, all watchers of that SKU receive an update. The operator's dashboard never falls behind.

**Event source**: DcbEventLog SNS EventTopic → Lambda → subscription push.

---

### 3. Real-Time Event Audit Log (DevOps / Admin)

Operators and developers need an observable view into what the system is doing — a live tail of domain events similar to `tail -f`. This is invaluable during incident response or system onboarding:

```graphql
subscription {
  onCatalogEventLog_eventAppended {
    position
    eventType
    aggregateId
    occurredAt
    payload
  }
}
```

Every event appended to the `CatalogPlugin` EventLog (or DcbEventLog) is streamed to this subscriber. Unlike application logs, this surface is typed and queryable. Auth restrictions keep it Admin-only.

**Event source**: EventLog / DcbEventLog → SNS EventTopic → Lambda → subscription push.

---

### 4. Collaborative Catalog Editing

A product management team has multiple editors working on a shared product catalog simultaneously. When one editor updates a product name or price, other editors' browsers should reflect the change immediately without requiring a page refresh:

```graphql
subscription {
  onCatalogProduct_stateChanged {
    id
    name
    price
    category
    lastEditedBy
  }
}
```

This subscription has no filter argument — it delivers any product state change to all subscribers. Combined with client-side cache invalidation (Apollo Client, urql), the UI always shows fresh data.

**Event source**: StateViewSlice (ProductsView) → QueryDb DynamoDB Stream → subscription push.

---

### 5. User Notification Push

A booking platform needs to notify a user the moment their reservation is confirmed. Rather than relying on email/SMS alone, the web app can display an in-app notification immediately:

```graphql
subscription {
  onBookingReservation_confirmed(userId: "user-99") {
    reservationId
    hotelName
    checkIn
    checkOut
    confirmationCode
  }
}
```

The subscription is filtered by `userId` so each client only receives its own notifications. The filter is enforced server-side via AppSync's subscription filter expressions — the client cannot receive other users' data.

**Event source**: StateViewSlice / EventLog → subscription push, with server-side filter on `userId`.

---

## Architecture Overview

Three distinct event sources can feed GraphQL subscriptions. They differ in what they observe and how they deliver updates to the subscription layer.

```
┌────────────────────────────────────────────────────────────────────┐
│  Source A: Domain events from EventLog / DcbEventLog               │
│                                                                    │
│  Aggregate.append() → SNS EventTopic → Lambda Subscriber           │
│                        (EventTopicPublisher_SNS)    │               │
│                                                     ▼               │
│                                             AppSync Realtime Push  │
└────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────┐
│  Source B: Read model state changes from QueryDb / StateViewSlice  │
│                                                                    │
│  QueryDb write → DynamoDB Stream → StateTopic Lambda               │
│  (QueryDbStorage_DynamoDbStream)         (StateTopic_AppSync)      │
│                                                     │               │
│                                                     ▼               │
│                                             AppSync Realtime Push  │
└────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────┐
│  Source C: Command acknowledgement (mutation-triggered)            │
│                                                                    │
│  AppSync Mutation resolves → @aws_subscribe built-in trigger       │
│  (zero extra infrastructure, fires on command accepted)            │
└────────────────────────────────────────────────────────────────────┘
```

---

## Generic Approach (reventless-core / reventless-spec)

The generic layer does not know about AppSync or WebSockets — it defines **what** can be subscribed to and provides the contracts that platform adapters implement.

### GraphqlSchema fragment extension

The `graphql-api-stitching` plan introduces `GraphqlSchema.fragment` with `types`, `queries`, and `mutations` fields. This plan extends that type with a fourth field:

```rescript
// In reventless-spec/src/components/GraphqlSchema.res
type fragment = {
  types: string,
  queries: string,
  mutations: string,
  subscriptions: string,  // NEW — bare fields for `type Subscription { ... }`
}
```

The `GraphqlSchemaStitcher` collects all `subscriptions` fragments alongside queries and mutations, wrapping them in a single `type Subscription { }` block in the final SDL.

### SubscriptionSource module type (reventless-spec)

A new module type that components can implement to declare what subscription topics they expose:

```rescript
// reventless-spec/src/components/SubscriptionSource.res
module type T = {
  // Human-readable SDL fragment for the Subscription type
  let subscriptionsFragment: string

  // Unique topic identifier used to route pushes
  // e.g. "CatalogProduct_stateChanged" or "CatalogEventLog_eventAppended"
  let topicName: string
}
```

Both `ReadModel` and `StateViewSlice` can implement `SubscriptionSource.T`. So can a new `EventLogSubscription` component for raw event streaming.

### SubscriptionPublisher adapter interface (reventless-spec)

The adapter interface that platform implementations must satisfy to publish to subscribers:

```rescript
// reventless-spec/src/adapter/SubscriptionPublisher.res
type publisherMaker<'api> = (
  ~name: string,
  ~api: 'api,
  ~topicName: string,
  ~opts: option<Pulumi.ComponentResource.options>,
) => {
  // Deploy-time: Pulumi resources created by this publisher
  resources: array<Adapter.resource>,
  // Runtime: function to push a JSON payload to all topic subscribers
  publish: Pulumi.Output.t<(~id: string, ~payload: JSON.t) => promise<unit>>,
}
```

This is analogous to `EventTopic_Adapter.publisherMaker` — same shape, different purpose.

### Plugin subscription outputs (reventless-spec)

`Plugin.outputs` gains a new field alongside `graphqlSchema`:

```rescript
type outputs = {
  ...existing fields...
  graphqlSchema: Pulumi.Output.t<GraphqlSchema.fragment>,   // includes subscriptions
  subscriptionSources: Pulumi.Output.t<array<subscriptionSource>>,  // NEW
}

type subscriptionSource = {
  topicName: string,
  publisherResource: Adapter.resource,  // the Lambda/HTTP resource that triggers pushes
}
```

### Core stitching (reventless-core)

`GraphqlSchemaStitcher.stitch` already combines types/queries/mutations from all plugins. It is extended to also merge subscription fragments into a single `type Subscription { }` block. No other changes to the stitcher.

---

## AWS/AppSync Approach (reventless-aws)

AppSync exposes both a `graphQL` endpoint (HTTPS, for queries/mutations) and a `realtime` endpoint (WSS, for subscriptions). The `AppSync_GraphQLApi.t` binding already exposes both URIs in its `uris` field — the infrastructure is there.

AppSync subscriptions work in two modes. Both are needed:

### Mode 1 — Mutation-triggered subscriptions (Source C)

The simplest mode. The SDL declares that a subscription field "listens" to one or more mutation fields via the `@aws_subscribe` directive. AppSync delivers the mutation result to all subscribers automatically — no extra infrastructure.

```graphql
type Subscription {
  onCatalogProduct_UpdateProductPrice(id: ID!): CatalogProduct
    @aws_subscribe(mutations: ["CatalogProduct_UpdateProductPrice"])
    @aws_auth(cognito_groups: ["User", "Admin"])
}
```

**When to use**: Immediate command acknowledgement. The subscription fires when the command is *accepted*, not when the resulting event is persisted. Good for optimistic UI patterns.

**Implementation**: `CommandGeneratorResolvers_AppSync` already generates Mutation resolvers. A new `CommandSubscriptionResolvers_AppSync` mirrors each mutation with a corresponding subscription field and its resolver (request template: `{return: null}`, response template: `$util.toJson($context.result)`).

**SDL generation**: The `Plugin_GraphqlSchema.res` helper (from the stitching plan) generates the subscriptions fragment alongside mutations. For each command mutation field `X_Command(...)`, it auto-generates:

```graphql
onX_Command(...same args...): ReturnType
  @aws_subscribe(mutations: ["X_Command"])
```

### Mode 2 — Real-time data source push (Sources A and B)

For event-driven updates that originate in DynamoDB Streams or SNS, AppSync's real-time service accepts programmatic pushes from Lambda. A Lambda function calls the AppSync Events HTTP API to publish data directly to a subscription topic, bypassing the mutation trigger.

**Deploy-time wiring**:

```
QueryDb (DynamoDB, streams enabled)
  ↓ [DynamoDB Stream → Lambda EventSourceMapping]
StateTopic_AppSync Lambda
  ↓ [HTTP POST to AppSync Events endpoint]
AppSync Realtime WebSocket
  ↓ [filtered push to matching subscribers]
Client WebSocket
```

**New component: `StateTopic_AppSync`** (`reventless-aws/src/adapter/StateTopic/StateTopic_AppSync.res`):

Implements `SubscriptionPublisher.publisherMaker`. At deploy time it creates:
1. A Lambda function that receives DynamoDB Stream records from the QueryDb/StateViewSlice table.
2. An IAM policy granting that Lambda `appsync:EventPublish` permission on the specific AppSync API.
3. A DynamoDB Stream → Lambda EventSourceMapping (reusing the pattern from `EventCollectorChannel_DynamoDbStream`).
4. The `publish` Output that, at runtime, calls the AppSync Events HTTP endpoint.

**New component: `EventLogSubscription_AppSync`** (`reventless-aws/src/adapter/EventLogSubscription/`):

Same structure as `StateTopic_AppSync` but triggered by the SNS EventTopic rather than a DynamoDB Stream. At deploy time it creates an SNS → SQS → Lambda chain (mirroring EventCollectorChannel). At runtime the Lambda maps the raw `{id, meta, event}` envelope to a subscription-friendly payload and publishes via the AppSync Events API.

**AppSync Events API call (runtime)**:

```rescript
// AppSync Events HTTP endpoint: https://<api-id>.appsync-realtime-api.<region>.amazonaws.com/event
// POST /event
// Body: { channel: "/default/<topicName>", events: [JSON.stringify(payload)] }
let publishToAppSync = (~apiId, ~region, ~topicName, ~payload) => {
  let endpoint = `https://${apiId}.appsync-realtime-api.${region}.amazonaws.com/event`
  // Signed with SigV4 using Lambda execution role credentials
  AwsSdk.AppSync.publishEvent(~endpoint, ~channel=`/default/${topicName}`, ~payload)
}
```

**SDL for real-time subscriptions**:

For a `ProductsView` StateViewSlice:

```graphql
type Subscription {
  onCatalogProduct_stateChanged(id: ID): CatalogProduct
    @aws_auth(cognito_groups: ["User", "Admin"])
}
```

The `id` argument is optional — if provided, AppSync filters server-side using an enhanced subscription filter expression so only the matching entity reaches the subscriber. If omitted, all state changes for that type are delivered.

**AppSync subscription filter expression** (deploy-time, set on the Resolver resource):

```json
{
  "filterGroup": [{
    "filters": [{
      "fieldName": "id",
      "operator": "eq",
      "value": { "ref": "ctx.args.id" }
    }]
  }]
}
```

This is set on the AppSync Resolver for the subscription field and evaluated per-event before delivery. The `AppSync_Resolver.res` binding's `args` type would need a `subscriptionFilter` optional field to support this.

---

## File Map

### New files

| Package | File | Purpose |
|---------|------|---------|
| `reventless-spec` | `src/components/SubscriptionSource.res` | `T` module type for subscription-capable components |
| `reventless-spec` | `src/adapter/SubscriptionPublisher.res` | `publisherMaker` adapter interface |
| `reventless-core` | `src/components/Plugin/Plugin_SubscriptionSchema.res` | Subscription SDL fragment generator (per-plugin) |
| `reventless-aws` | `src/adapter/StateTopic/StateTopic_AppSync.res` | QueryDb/StateViewSlice → AppSync push (Source B) |
| `reventless-aws` | `src/adapter/EventLogSubscription/EventLogSubscription_AppSync.res` | EventLog/DcbEventLog SNS → AppSync push (Source A) |
| `reventless-aws` | `src/adapter/CommandSubscription/CommandSubscriptionResolvers_AppSync.res` | Mutation-triggered subscription resolvers (Source C) |

### Modified files

| Package | File | Change |
|---------|------|--------|
| `reventless-spec` | `src/components/GraphqlSchema.res` | Add `subscriptions: string` field to `fragment` |
| `reventless-spec` | `src/components/Plugin.res` | Add `subscriptionSources` to `outputs` |
| `reventless-core` | `src/core/GraphqlSchemaStitcher.res` | Merge subscription fragments into `type Subscription { }` |
| `reventless-core` | `src/components/Plugin/Plugin_Builder.res` | Call `Plugin_SubscriptionSchema` and populate `subscriptionSources` |
| `reventless-aws` | `src/core/Core_AppSync_Builder.res` | Wire subscription publishers alongside mutation/query resolvers |
| `rescript/rescript-pulumi-aws` | `src/AppSync/AppSync_Resolver.res` | Add optional `subscriptionFilter` field to resolver `args` |
| `rescript/rescript-pulumi-aws` | `src/AppSync/AppSync_GraphQLApi.res` | Add `additionalAuthenticationProviders` to support mixed auth on subscription fields |

---

## Subscription SDL Example (full plugin fragment)

```graphql
# Subscription fields contributed by the Catalog plugin

type Subscription {

  # Source C — mutation-triggered: fires when command is accepted
  onCatalogProduct_CreateProduct(id: ID!, name: String!, price: Float!): String!
    @aws_subscribe(mutations: ["CatalogProduct_CreateProduct"])
    @aws_auth(cognito_groups: ["Admin"])

  onCatalogProduct_UpdateProductPrice(id: ID!, price: Float!): String!
    @aws_subscribe(mutations: ["CatalogProduct_UpdateProductPrice"])
    @aws_auth(cognito_groups: ["Admin"])

  # Source B — state change: fires when read model is updated
  onCatalogProduct_stateChanged(id: ID): CatalogProduct
    @aws_auth(cognito_groups: ["User", "Admin"])

  # Source A — raw event stream: fires on every appended event
  onCatalogEventLog_eventAppended: CatalogEventLogEvent
    @aws_auth(cognito_groups: ["Admin"])
}

type CatalogEventLogEvent {
  position: Int!
  eventType: String!
  aggregateId: ID!
  occurredAt: String!
  payload: AWSJSON!
}
```

---

## Dependency on the GraphQL API Stitching Plan

This plan extends `docs/plans/Backlog/graphql-api-stitching.md`. Specifically:

- `GraphqlSchema.fragment` must already include the `subscriptions` field (Phase 1 of stitching plan).
- `GraphqlSchemaStitcher` must already handle the merging pattern (Phase 3 of stitching plan).
- `Core_AppSync_Builder` is the integration point where both plans converge (Phase 4 of stitching plan).

The subscription work **cannot start** until Phases 1 and 3 of the stitching plan are complete.

---

## Open Questions

1. **AppSync Events API vs. `@aws_subscribe` directive**: For Sources A and B, the newer AppSync Events API (HTTP push) is more flexible than the Lambda data source trigger pattern. Should the implementation use the Events API directly, or the older Lambda-triggered Subscription resolver approach? The Events API requires AppSync `GRAPHQL_API_TYPE: GRAPHQL` (the default), while a future "Pub/Sub" API type uses channel-based semantics. The plan currently assumes the standard GraphQL API with Events API push.

2. **Subscription filter granularity**: Should server-side filters be generated automatically from the read-model key structure (e.g., `id` is always filterable), or should plugin authors declare which fields are subscription filter arguments explicitly?

3. **Authentication for push Lambda**: The `StateTopic_AppSync` Lambda needs `appsync:EventPublish` permission scoped to the specific API ARN. Should this be part of the Lambda's execution role (simpler) or a separate AppSync service role?

4. **In-memory / local dev subscriptions**: The `reventless-in-memory` package uses GraphQL Yoga. Yoga v5 supports subscriptions via `createPubSub`. An `InMemory` subscription publisher would use the Yoga PubSub internally. This is needed for the test suite to cover subscription behaviour.

5. **Subscription event schema vs. state schema**: For Source B (state changes), should the subscription payload be the full current state (re-fetched after update) or just the changed fields (the DynamoDB Stream `NewImage`)? The former is more convenient for clients; the latter is more efficient and avoids a round-trip query.

6. **At-most-once vs. at-least-once delivery**: AppSync WebSocket subscriptions do not guarantee delivery if the client disconnects and reconnects. Should the framework provide a "catch-up" mechanism (e.g., query the QueryDb for the latest state on reconnect)?

---

## Implementation Order

```
Prerequisite: graphql-api-stitching plan Phases 1–3 (GraphqlSchema.fragment, stitcher)

Phase 1: Add `subscriptions` field to GraphqlSchema.fragment and SubscriptionSource.T spec
Phase 2: Plugin_SubscriptionSchema.res — auto-generate subscription fragment from spec
Phase 3: Plugin_Builder — populate subscriptions fragment and subscriptionSources in outputs
Phase 4: StateTopic_AppSync — QueryDb DynamoDB Stream → AppSync push (Source B)
Phase 5: CommandSubscriptionResolvers_AppSync — mutation-triggered subscriptions (Source C)
Phase 6: EventLogSubscription_AppSync — SNS EventTopic → AppSync push (Source A)
Phase 7: Core_AppSync_Builder — wire all subscription publishers alongside resolvers
Phase 8: InMemory subscription support (Yoga PubSub) for local dev and tests
```

---

## Status

- [ ] Prerequisite: graphql-api-stitching plan Phases 1–3 complete
- [ ] Phase 1: `subscriptions` in `GraphqlSchema.fragment` + `SubscriptionSource.T` in spec
- [ ] Phase 2: `Plugin_SubscriptionSchema.res` subscription fragment generator
- [ ] Phase 3: Plugin_Builder wires subscription outputs
- [ ] Phase 4: `StateTopic_AppSync` — read model state-change push
- [ ] Phase 5: `CommandSubscriptionResolvers_AppSync` — mutation-triggered subscriptions
- [ ] Phase 6: `EventLogSubscription_AppSync` — raw event stream push
- [ ] Phase 7: `Core_AppSync_Builder` subscription wiring
- [ ] Phase 8: In-memory / Yoga subscription support
