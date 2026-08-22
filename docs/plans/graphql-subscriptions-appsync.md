# Plan: GraphQL Subscriptions — AppSync Real-Time Infrastructure

## Status: Phases 1–6 complete. Source C verified in AWS. Source B publish chain verified (DDB Stream → Lambda → AppSync Events HTTP publish — two latent Lambda handler bugs fixed, see Phase 4). **WebSocket subscriber verification closed 2026-08-22** — descriptors observed arriving over the deployed Events transport, so the format recorded as blocked since 2026-04-18 was correct all along for that path. What remains broken is the *lifecycle* subscription path, for two independent reasons, one of which is core's: no explicit subscription endpoint is written into `config.json`. See Phase 4's verify items. Source A infrastructure ready but no SNS-backed event topics currently deployed in the example stack.

### Bug fixed (2026-04-18): `Plugin_SubscriptionSchema.sourceCFields` used `String.replace(": String!", ...)` which replaced the first occurrence — hitting String! args before the return type. Fixed to `sub ++ @aws_subscribe directive` (append at end). Deployed fragments and pushed corrected schema.

### Infrastructure fixes (2026-04-18):
- `QueryDbStorage_DynamoDbStream` now returns both DynamoDb + DynamoDbStream resources so QueryEngine and StateTopic each find their service type
- `StateTopic_AppSync` extracts stream ARN from `resourceInfo.StreamSource.sourceUrn`, creates `EventSourceMapping` directly (not via `Util_EventSourceMapping` which used table ARN)
- `EventTopicPublisher_SNS` tracks SNS-backed topics in `snsRegistry`; Phase 5 guards skip DDB stream topics (Category aggregate, Catalog DCB use `EventTopicPublisher_DynamoDbStream`)
- `Platform.res` reconstructs `AppSync_EventsApi.t` from StackReference exports in plugin mode (no Obj.magic — `defaultNamespace: None`)
- Phase 4 creates a NONE data source per StateTopic (AppSync UNIT resolvers require one)
- Subscription resolver code fixed: `extensions.setSubscriptionFilter` (not `ctx.extensions`), `return {}` for filtered resolvers

---

## Context and Motivation

Reventless platforms expose a GraphQL API through which clients issue commands and query read-model state. All of that is currently request/response: the client asks, the server answers. Clients have to poll to discover state changes.

GraphQL subscriptions eliminate polling by opening a persistent WebSocket connection and pushing updates the moment they become available. This plan covers the complete AppSync subscription infrastructure and its local (yoga) counterpart for local development.

This plan supersedes [graphql-subscriptions-realtime.md](Backlog/graphql-subscriptions-realtime.md), preserving its architectural design (Sources A, B, C; AppSync Events API push) and adding concrete implementation steps, file maps, and checklists. That backlog plan is archived.

**Related plan**: [reventless-client-transport.md](Backlog/reventless-client-transport.md) covers the direct HTTP command endpoint and `pullEvents` catch-up query — client transport concerns that are independent of subscriptions.

---

## Scope

| Capability | AWS (production) | Local (yoga, dev) |
|-----------|------------------|-----------------------|
| `@aws_subscribe` mutation-triggered subscriptions (Source C) | AppSync resolver on `Subscription` type | yoga subscription via PubSub |
| State-change subscriptions — projected state pushed on QueryDb write (Source B) | DynamoDB Stream → Lambda → AppSync Events API | yoga subscription via PubSub |
| Raw event stream subscriptions (Source A) | SNS EventTopic → SQS → Lambda → AppSync Events API | yoga subscription via PubSub |

**Out of scope**: HTTP command endpoint (`reventless-client-transport.md`). `pullEvents` catch-up query. The `reventless-client` library itself. API Gateway WebSocket bidirectional transport. Offline-first SQLite WASM bindings.

---

## Background: Three Subscription Sources

```
Source A — Raw domain events
  EventLog / DcbEventLog → SNS EventTopic → SQS → Lambda → AppSync Events API → Client

Source B — Read model state changes
  QueryDb write → DynamoDB Stream → StateTopic Lambda → AppSync Events API → Client

Source C — Mutation-triggered (zero extra infrastructure)
  AppSync Mutation resolves → @aws_subscribe built-in trigger → Client
```

Source C fires when a command is *accepted* — before the resulting event is projected.
Sources A and B fire after the event is fully processed.

### Important: Two distinct delivery mechanisms

**Source C** uses traditional AppSync GraphQL subscriptions (`@aws_subscribe`). Clients connect to the GraphQL WebSocket endpoint and subscribe to SDL fields in `type Subscription`. AppSync handles delivery automatically when the triggering mutation executes.

**Sources A and B** use the **AppSync Events (Pub/Sub) service** — a different real-time API from GraphQL subscriptions. Lambdas publish to named channels (`/default/{channelName}`). Clients subscribe via the AppSync Events WebSocket endpoint (not the GraphQL WebSocket). The `type Subscription` SDL fields for Sources A and B serve as documentation and client type generation — they do not use `@aws_subscribe`.

This distinction affects client-side code: a client needs two separate connections to receive all three sources. Source C via the GraphQL WebSocket, Sources A and B via the AppSync Events WebSocket.

---

## Architectural decisions made during implementation

| Decision | Chosen | Rationale |
|----------|--------|-----------|
| `subscriptionFilter` storage | Embedded in resolver code string (not a Pulumi property) | AppSync sets filters via `ctx.extensions.setSubscriptionFilter()` in JS code; no `subscriptionFilter` property exists on the `CreateResolver` API |
| `GraphqlSchema.fragment` location | `fragmentParts` in `GraphQL_Stitcher.res` (reventless-core), not a new field in reventless-spec | The `apiSchemaFragment` in reventless-spec is an opaque `{encoded, protocol}` envelope; fragment fields live inside the encoded JSON |
| Stream enablement opt-in | Use `QueryDbStorage_DynamoDbStream` adapter (already existed) | Avoids modifying the `storageMaker` type signature and breaking all existing implementations |
| Phase 4 handler bundling | Inline ESM string in `StateTopic_AppSync.res` | Follows `Util_DeadLetterQueue.res` pattern; no separate handler file needed |
| Phase 4 wiring | Opt-in call to `StateTopic_AppSync.make` per QueryDb | Avoids breaking existing plugin deployments; plugin authors explicitly activate per ReadModel/StateViewSlice |
| `Core_AppSync_Builder.res` | Not created | Wiring done directly in `CommandGeneratorResolvers_AppSync.res` (Phases 3) and left as opt-in for Phases 4–5 |

---

## Phase 1 — `subscriptions` field and resolver builders ✅

**Files changed**: `reventless-core`, `reventless-aws`

### What was built

Added `subscriptions: array<string>` to `fragmentParts` in `GraphQL_Stitcher.res`:
- `encode` serialises it to JSON key `"subscriptions"`
- `decode` reads it back (old fragments without the key decode to `[]`)
- `stitch` collects subscription fields with collision detection and emits `type Subscription { ... }` when any fields are present

Added `makeSubscriptionResolver` to both resolver builders:
- `AppSync_Resolver_Native.res` — wraps `Native.make` on `typeName: "Subscription"`
- `AppSync_Resolver_Retrying.res` — wraps `makeResolver` (dynamic provider with retry)
- Both generate inline AppSync JS: `request` sets optional `setSubscriptionFilter`, `response` returns `ctx.result`
- Both accept `~subscriptionFilter: option<string>=?` (JSON filter expression injected into the resolver code string)

Backfilled `subscriptions: []` in all `GraphQL_Stitcher.encode({...})` call sites.
Added `"subscriptions": []` to `GraphQL_FragmentGenerator.generate` encoded output.

### Checklist
- [x] `subscriptions: array<string>` in `fragmentParts` (encode + decode + stitch)
- [x] `subscriptions: []` backfilled in all `encode({...})` call sites (Platform.res × 2, AppSync_AdapterTest.res × 3, GraphQL_FragmentGenerator.generate)
- [x] `makeSubscriptionResolver` in `AppSync_Resolver_Native.res`
- [x] `makeSubscriptionResolver` in `AppSync_Resolver_Retrying.res`
- [x] Build clean — zero warnings, zero errors

---

## Phase 2 — SDL generation: subscription fragment per plugin ✅

**Files changed/created**: `reventless-core`

### What was built

**`Plugin_SubscriptionSchema.res`** (`reventless-core/src/components/Plugin/`):

Generates three categories of subscription SDL fields from the same data already available in `Plugin_Builder`:

| Source | Input | Output |
|--------|-------|--------|
| C | `mutationEntries` (fieldNames + commandSchema) | `onX(id: ID!, ...args): String` + `@aws_subscribe(mutations: ["X"])` |
| B | `queryEntries` (returnTypeName) | `on{ReturnTypeName}_stateChanged(id: ID): {ReturnTypeName}` |
| A | `eventLogEntries` (displayName) | `on{Name}EventLog_eventAppended: {Name}EventLogEvent` + supporting type |

Source C mirrors the mutation arg derivation exactly (reuses `GraphQL_FragmentGenerator.deriveMutationFieldFromObject`). Payload-less command variants are skipped (same as mutations).

Source A includes the `{Name}EventLogEvent` type with `AWSJSON` payload. Note: `AWSJSON` is an AppSync scalar — not available in graphql-yoga. Phase 6 will need to substitute `String` for the local SDL.

**`Plugin_Builder.res`** wiring: replaced the single `generateFragment` call with:
```rescript
let baseFragment = FragmentProvider.generateFragment(~mutationEntries, ~queryEntries)
let subResult = Plugin_SubscriptionSchema.generate(~mutationEntries, ~queryEntries, ~eventLogEntries)
let apiSchemaFragment = GraphQL_Stitcher.encode({
  ...GraphQL_Stitcher.decode(baseFragment),
  types: Array.concat(parts.types, subResult.extraTypes),
  subscriptions: subResult.subscriptionFields,
})
```

### Checklist
- [x] `Plugin_SubscriptionSchema.res` created
- [x] Source C fields (one per command variant; mirrors mutation args; `@aws_subscribe`)
- [x] Source B fields (one per `returnTypeName`; optional `id: ID` filter arg)
- [x] Source A fields + `{Name}EventLogEvent` types (`AWSJSON` payload, `originatorSlice`)
- [x] `fragment.subscriptions` + extra types populated in `Plugin_Builder.res`
- [x] `GraphQL_Stitcher.stitch` emits `type Subscription { }` (done in Phase 1)
- [x] Build clean — zero warnings, zero errors

---

## Phase 3 — Source C: Mutation-triggered subscriptions ✅

**Files created/changed**: `reventless-aws`

### What was built

**`CommandSubscriptionResolvers_AppSync.res`** (`reventless-aws/src/adapter/Api/`):

```rescript
let make = (~api, ~mutationFields, ~opts) =>
  mutationFields->Array.forEach(field =>
    AppSync_Resolver_Retrying.makeSubscriptionResolver(
      ~name="on" ++ field->String.capitalize,
      ~api,
      ~field="on" ++ field,
      ~opts,
    )
  )
```

No data source needed. AppSync delivers the mutation's return value to subscribers via `@aws_subscribe` automatically.

**Wiring** in `CommandGeneratorResolvers_AppSync.res`:
- End of `make` (aggregate mutations): `CommandSubscriptionResolvers_AppSync.make(~api, ~mutationFields=fields, ~opts)`
- End of `makeDcb` (DCB mutations): same call with `~mutationFields=fieldNames`

### Checklist
- [x] `CommandSubscriptionResolvers_AppSync.res` created
- [x] One `Subscription.onX` resolver per mutation field
- [x] Wired into `CommandGeneratorResolvers_AppSync.make` (aggregates) and `makeDcb` (DCB slices)
- [x] Verified in deployed AppSync schema (all 28 Source C fields have @aws_subscribe; UNIT resolvers confirmed)

---

## Phase 4 — Source B: State-change subscriptions ✅ (infrastructure) / ⬜ (wiring)

**Files created**: `reventless-aws`

### What was built

**`StateTopic_AppSync.res`** (`reventless-aws/src/adapter/StateTopic/`):

```rescript
StateTopic_AppSync.make(
  ~name,          // QueryDb name, e.g. "CatalogProduct"
  ~topicName,     // AppSync Events channel name, e.g. "catalog_Product"
  ~queryDbResources,  // from QueryDbStorage_DynamoDbStream output
  ~api,
  ~opts,
)
```

Deploy-time resources created:
1. **IAM role** — Lambda service principal with three policy statements: CloudWatch Logs, DynamoDB Stream read (4 actions), `appsync:GraphQL` on `{apiArn}/*`
2. **Lambda** (`{name}StateTopicLambda`) — inline ESM handler that:
   - Skips `REMOVE` events
   - Unmarshals `NewImage` via `@aws-sdk/util-dynamodb`
   - Publishes to AppSync Events channel `/default/{topicName}` via lazy-imported `@aws-sdk/client-appsync-events`
   - `APPSYNC_ENDPOINT` env var wired from `api.uris.graphQL` output
3. **EventSourceMapping** — DynamoDB stream ARN (from `queryDbResources`) → Lambda

Stream enablement: use `QueryDbStorage_DynamoDbStream` (already existed — creates tables with `streamViewType: NEW_AND_OLD_IMAGES`). No change to `storageMaker` type was needed.

### What remains

Wiring `StateTopic_AppSync.make` per ReadModel/StateViewSlice is left as opt-in for plugin authors. A future `Core_AppSync_Builder.res` could auto-wire it when `QueryDbStorage_DynamoDbStream` is detected. The subscription filter (`setSubscriptionFilter` keyed to the state `@id` field name) is also pending the wiring step.

### Checklist
- [x] `StateTopic_AppSync.res` created (Lambda + IAM + EventSourceMapping)
- [x] Inline Lambda handler: DynamoDB Stream → AppSync Events API
- [x] Stream opt-in via `QueryDbStorage_DynamoDbStream` (already existed)
- [x] Wire `StateTopic_AppSync.make` per stream-enabled QueryDb via `subscriptionInfraHook` in `Platform.res`
- [x] Set `subscriptionFilter` on `makeSubscriptionResolver` — hardcoded `"id"` field (see Q4 Option A)
- [x] NONE data source per StateTopic for AppSync UNIT resolver requirement
- [x] `ProductsStream2ProductsStateTopic` + `ProductDemandStream2ProductDemandStateTopic` ESMs deployed
- [x] `onCatalog_ProductStateChanged` + `onCatalog_ProductDemandStateChanged` subscription resolvers deployed
- [x] Verify: state change → publish chain (DDB Stream → Lambda → AppSync Events HTTP publish)
  - Two pre-existing bugs fixed: (1) handler used nonexistent `@aws-sdk/client-appsync-events` — replaced with native SigV4+fetch; (2) AppSync Events channels forbid underscores — `topicName` normalized via `_`→`-`
  - Verified via direct DDB write to `Products-07b7f5f` table: DDB Stream fired, Lambda invoked, zero errors in CloudWatch
  - Verified HTTP publish format via direct `POST /event` calls: 200 OK for `/default/catalog-Product` channel
- [x] Verify: push reaches WebSocket subscriber. **Closed 2026-08-22** — the shipped Events client was
      driven against the deployed `alpha` Events API with a Cognito id token and observed
      `connection_ack` → `subscribe_success` → `Added`/`Updated` change descriptors for commands fired
      on the same run. The subscribe-message format this plan wrote against the public docs is what the
      deployed API accepts.

      **The `Sec-WebSocket-Protocol` note above was two problems wearing one symptom.** For the Events
      transport, `aws-appsync-event-ws` + `header-<base64url>` was always right. For the **lifecycle**
      subscriptions (`onPluginStatusChange`, `onUIFragmentChange`) both halves are wrong: they are aimed
      at the query host `<id>.appsync-api…` rather than `<id>.appsync-realtime-api…`, *and* AWS refuses
      the `graphql-transport-ws` subprotocol the npm `graphql-ws` client sends, accepting only its own
      `graphql-ws`. Fixing either alone leaves them dark.

- [ ] **Write an explicit subscription endpoint into `config.json`.** The client currently derives one
      by promoting `platformApiEndpoint`'s scheme, because `Platform.res` writes none — so the
      derivation lands on the query host, which never accepts a socket. This half is core's, and it is
      the only part of the lifecycle-subscription failure that is. The subprotocol half, and the choice
      between speaking AWS's `graphql-ws` or moving these two subscriptions onto the Events transport,
      belong to the client.

---

## Phase 5 — Source A: Raw event stream subscriptions ⬜

**Target packages**: `reventless-aws`

### Architecture

```
EventTopic (SNS) ──► SQS buffer ──► EventLogSubscription Lambda ──► AppSync Events API ──► Client
```

Each plugin's EventTopic (SNS) triggers a Lambda (via SQS) that pushes raw events to an AppSync Events channel. Admin/observability only.

### `EventLogSubscription_AppSync.res` — what to build

Deploy-time resources (follow the SQS/SNS pattern from `EventCollectorChannel_DynamoDbStream`):
1. SQS queue + dead-letter queue
2. SNS → SQS subscription (`Util_SQS.subscribeToSnsTopic`)
3. Lambda + IAM role (`appsync:GraphQL` on API ARN + SQS receive permissions)
4. EventSourceMapping: SQS → Lambda

Lambda handler:
```javascript
export async function handler(event) {
  const { PublishEvents } = await import("@aws-sdk/client-appsync-events");
  const client = await getClient();
  for (const record of event.Records) {
    const body = JSON.parse(record.body);
    const originatorSlice = body.tags?.find(t => t.key === "originatorSlice")?.value;
    await client.send(new PublishEvents({
      channelNamespace: "default",
      channelName: TOPIC_NAME,
      events: [JSON.stringify({
        position: body.position,
        eventType: body.eventType,
        payload: body.data,
        originatorSlice,
      })),
    }));
  }
}
```

Call site: `EventLogSubscription_AppSync.make(~name, ~topicName, ~eventTopic, ~api, ~opts)` per entry in `eventLogEntries`.

### Checklist
- [x] Create `reventless-aws/src/adapter/EventLogSubscription/EventLogSubscription_AppSync.res`
- [x] SQS queue (60 s visibility, redrive → shared DLQ) + SNS→SQS subscription (rawMessageDelivery)
- [x] SQS queue policy allowing SNS to send
- [x] Lambda + IAM role (CloudWatch Logs + SQS receive + `appsync:GraphQL`)
- [x] EventSourceMapping: SQS → Lambda (`Util_EventSourceMapping.subscribeSqs`)
- [x] Inline handler: parse SNS body → extract `originatorSlice` from tags → publish to AppSync Events channel
- [x] Wire `EventLogSubscription_AppSync.make` per SNS-backed entry in `eventLogEntries` via `subscriptionInfraHook` in `Platform.res`
- [x] Guard: DDB stream event topics (Category, Catalog DCB) skipped via `EventTopicPublisher_SNS.snsRegistry`
- [x] Handler fixes applied (same as Source B): native SigV4+fetch replacing nonexistent SDK + underscore→hyphen channel normalization
- [ ] Verify: domain event → push reaches admin WebSocket subscriber — no SNS-backed event topics currently deployed in the hybrid example stack (all aggregate event topics use `EventTopicPublisher_DynamoDbStream`); requires a plugin with `EventTopicPublisher_SNS` configured to exercise end-to-end

---

## Phase 6 — Local WebSocket subscriptions ⬜

**Target packages**: `reventless-local`

### Motivation

The local dev experience must mirror production so client code works unchanged between environments. graphql-yoga v5 supports GraphQL subscriptions natively via `createPubSub` and the `graphql-ws` protocol.

Note: Sources A and B in production use AppSync Events (Pub/Sub). The local server uses graphql-yoga's PubSub which uses a different protocol. This is an acceptable dev/prod divergence for local development — the data shape is identical.

Also note: the `AWSJSON` scalar used in Source A's `{Name}EventLogEvent` type must be replaced with `String` (or removed from the SDL) in the local schema, since yoga does not define `AWSJSON`.

### What to build

**`LocalBus` extension**: Add `createPubSub()` instance; publish to it whenever state changes or events are appended.

**`LocalGraphQL_SubscriptionResolvers.res`**: Registers yoga subscription resolvers that subscribe to the PubSub and yield events to WebSocket clients.

**`Platform.res`**: Wire subscription resolvers into the yoga server setup.

### Checklist
- [x] `createPubSub` + `pubSubPublish` + `pubSubSubscribe` bindings added to `GraphqlYoga.res`
- [x] `publishStateChange` / `subscribeToStateChanges` added to `LocalBus.T` + `Impl`
- [x] `QueryDbStorage_InMemory.save/saveBatch` call `Bus.publishStateChange` after each write (Source B hook)
- [x] Source A hook: `LocalEventTopicPublisher` already calls `Bus.publishEvent`; `bridgeSourceA` subscribes and forwards to yoga PubSub
- [x] `LocalGraphQL_SubscriptionResolvers.res` created with `bridgeSourceA`, `bridgeSourceB`, `registerAll`
- [x] `registerSubscriptions` added to `GraphQL_ServerInstance.t` + `make` + `GraphQL_ServerInstance.res` (build/start/reset)
- [x] `registerSubscriptions` added to `DomainGraphQL_Server.res` singleton + `asInterface`
- [x] `PlatformGraphQL_Server.res` re-export updated
- [x] `subscriptionFields: array<string>` added to `mcpRegistrationParams`; `Plugin_Builder.res` + `Platform_Admin.res` backfilled
- [x] `Platform.res` `mcpSchemaRegistrationHook` wires Source A + B bridges and calls `registerAll`
- [x] `scalar AWSJSON` injected via `registerAll` → `server.registerTypes` so yoga accepts the AppSync scalar
- [x] Build clean — zero warnings, zero errors
- [x] Integration test at `tests/adapter/GraphQL_SubscriptionResolversTest.res` — 3 test cases (Source A, Source B positive, Source B negative); verifies bus → yoga PubSub bridge end-to-end

---

## File Map

### New files (created)

| Package | File | Phase | Purpose |
|---------|------|-------|---------|
| `reventless-core` | `src/components/Plugin/Plugin_SubscriptionSchema.res` | 2 | Subscription SDL fragment generator (Sources A, B, C) |
| `reventless-aws` | `src/adapter/Api/CommandSubscriptionResolvers_AppSync.res` | 3 | Source C: `Subscription.onX` resolver per mutation field |
| `reventless-aws` | `src/adapter/StateTopic/StateTopic_AppSync.res` | 4 | Source B: DynamoDB Stream → Lambda → AppSync Events API |
| `reventless-aws` | `src/adapter/EventLogSubscription/EventLogSubscription_AppSync.res` | 5 | Source A: SNS → SQS → Lambda → AppSync Events API |
| `reventless-local` | `src/adapter/Api/LocalGraphQL_SubscriptionResolvers.res` | 6 | WebSocket subscriptions for yoga (Sources A, B, C) |

### Modified files

| Package | File | Phase | Change |
|---------|------|-------|--------|
| `reventless-core` | `src/components/Api/GraphQL_Stitcher.res` | 1 | `subscriptions` field in `fragmentParts`; stitch emits `type Subscription { }` |
| `reventless-core` | `src/components/Api/GraphQL_FragmentGenerator.res` | 1 | Emit `"subscriptions": []` in generated JSON |
| `reventless-aws` | `src/adapter/Api/AppSync_Resolver_Native.res` | 1 | `makeSubscriptionResolverCode` + `makeSubscriptionResolver` |
| `reventless-aws` | `src/adapter/Api/AppSync_Resolver_Retrying.res` | 1 | `makeSubscriptionResolverCode` + `makeSubscriptionResolver` |
| `reventless-aws` | `src/Platform.res` | 1 | Backfill `subscriptions: []` in `emptyBaseFragment` |
| `reventless-local` | `src/Platform.res` | 1 | Backfill `subscriptions: []` in `emptyBaseFragment` |
| `reventless-aws` | `tests/AppSync_AdapterTest.res` | 1 | Backfill `subscriptions: []` in three encode calls |
| `reventless-core` | `src/components/Plugin/Plugin_Builder.res` | 2 | Inject subscriptions via decode/re-encode after `generateFragment` |
| `reventless-aws` | `src/adapter/CommandGenerator/CommandGeneratorResolvers_AppSync.res` | 3 | Call `CommandSubscriptionResolvers_AppSync.make` after mutation resolvers |
| `reventless-local` | `src/adapter/LocalBus.res` | 6 | Add PubSub + publish to PubSub on state change / event append |
| `reventless-local` | `src/Platform.res` | 6 | Wire subscription resolvers into yoga server |

---

## Subscription SDL: Full example (Catalog plugin)

```graphql
type Subscription {

  # Source C — fires when command is ACCEPTED (instant, @aws_subscribe)
  onCatalogPlugin_Product_AddProduct(id: ID!, name: String!, price: Float!, categoryId: ID!): String
    @aws_subscribe(mutations: ["CatalogPlugin_Product_AddProduct"])

  onCatalogPlugin_Product_ChangeProductPrice(id: ID!, price: Float!): String
    @aws_subscribe(mutations: ["CatalogPlugin_Product_ChangeProductPrice"])

  # Source B — fires when READ MODEL STATE CHANGES (pushed via AppSync Events API)
  oncatalog_Product_stateChanged(id: ID): catalog_Product
  oncatalog_Category_stateChanged(id: ID): catalog_Category

  # Source A — raw event stream, admin/observability only (pushed via AppSync Events API)
  onCatalogPluginEventLog_eventAppended: CatalogPluginEventLogEvent
}

type CatalogPluginEventLogEvent {
  position: String!
  eventType: String!
  payload: AWSJSON!
  originatorSlice: String
}
```

*(Field name casing derives from actual `fieldNames` / `returnTypeName` values at runtime.)*

---

## Dependency Order

```
Phase 1 (subscriptions field + resolver builders) ✅
    ↓
Phase 2 (SDL generation) ✅
    ↓
Phase 3 (Source C - @aws_subscribe resolvers) ✅
Phase 4 (Source B - state-change push infra) ✅ / ⬜ plugin-builder wiring
Phase 5 (Source A - event stream infra)       ✅ / ⬜ plugin-builder wiring
Phase 6 (local WebSocket)                     ✅ / ⬜ integration test
```

---

## Open Questions

0. **✅ RESOLVED — Sources A and B: AppSync Events API vs GraphQL API mismatch** *(Option A implemented)*: `StateTopic_AppSync` and `EventLogSubscription_AppSync` use `@aws-sdk/client-appsync-events` and derive `APPSYNC_ENDPOINT` from the GraphQL API's `uris.graphQL` output. The AppSync Events Pub/Sub service (`aws.appsync.Api` in aws-native) is a **completely separate resource** from the AppSync GraphQL API (`aws.appsync.GraphQlApi`); pointing the Events client at the GraphQL endpoint will fail. No `aws.appsync.Api` resource exists in the current Reventless stack. Source C (`@aws_subscribe`) is unaffected — it runs entirely on the existing GraphQL API.

   **Option A — Create a separate `aws.appsync.Api` (Events API) resource**: Provision an AppSync Events API alongside the GraphQL API. Update `StateTopic_AppSync` and `EventLogSubscription_AppSync` to accept the Events API endpoint and ARN separately. IAM `appsync:GraphQL` permission targets the Events API ARN. Clients subscribe via the EventApi WebSocket endpoint (different from the GraphQL WebSocket — see Q2). Architecturally cleanest but adds a new resource type, a second WebSocket endpoint for clients, and requires `@aws-sdk/client-appsync-events` in the Lambda layer (see Q1).

   **Option B — Replace Events push with a NONE data source + `@aws_subscribe` mutation (recommended)**:

   A NONE data source is an AppSync data source type with no backend. Instead of calling DynamoDB, Lambda, or an HTTP endpoint, AppSync returns whatever the resolver's request mapping template produces directly. Because AppSync `@aws_subscribe` delivers the *return value of the triggering mutation* to subscribers, a Lambda can call a NONE-backed mutation with any payload and AppSync will fan it out to all matching subscribers — with no additional AWS service.

   **SDL changes required** (added to the base fragment, not plugin fragments):
   ```graphql
   # Envelope types — one per push category
   type StateChangePush { typeName: String! id: String! state: AWSJSON! }
   type EventAppendedPush { displayName: String! eventType: String! payload: AWSJSON! originatorSlice: String }

   # Push mutations — called by Lambdas, not by clients; prefixed _ to signal internal use
   _pushStateChange(typeName: String!, id: String!, state: AWSJSON!): StateChangePush
   _pushEventAppended(displayName: String!, eventType: String!, payload: AWSJSON!, originatorSlice: String): EventAppendedPush

   # Client subscriptions — gain @aws_subscribe; replace the current non-@aws_subscribe Source B/A fields
   on{ReturnTypeName}_stateChanged(typeName: String!, id: ID): StateChangePush
     @aws_subscribe(mutations: ["_pushStateChange"])
   on{DisplayName}EventLog_eventAppended(displayName: String!): EventAppendedPush
     @aws_subscribe(mutations: ["_pushEventAppended"])
   ```

   **Payload trade-off**: the push payload is a generic `{typeName, id, state: AWSJSON}` envelope — clients parse `state` themselves rather than receiving a typed `CatalogProduct` directly. Option A (AppSync Events API) would deliver the typed payload.

   **Lambda push call** (replaces `AppSyncEventsClient`):
   ```javascript
   // IAM-signed HTTP POST to the GraphQL endpoint — no new SDK needed
   // @aws-sdk/client-appsync already in codebase; or use raw SigV4 + fetch
   const { AppSyncClient, executeGraphQL } = await import("@aws-sdk/client-appsync");
   const client = new AppSyncClient({ region: AWS_REGION });
   await client.send(new ExecuteGraphQL({
     apiId: API_ID,
     document: `mutation { _pushStateChange(typeName: "${typeName}", id: "${id}", state: ${JSON.stringify(stateJson)}) { typeName id } }`,
   }));
   ```

   **Infrastructure changes**: replace `@aws-sdk/client-appsync-events` handler code in `StateTopic_AppSync` and `EventLogSubscription_AppSync` with signed GraphQL mutation calls; add NONE data source Pulumi resources for `_pushStateChange` and `_pushEventAppended`; update the Source B/A subscription SDL fields in `Plugin_SubscriptionSchema` to add `@aws_subscribe`. No new `aws.appsync.Api` resource needed; all three sources use the same GraphQL WebSocket endpoint.

   **Option C — Defer Sources A and B; ship Source C now**: Source C is fully wired and works with the existing GraphQL API. Ship it. Defer the A/B decision until the endpoint architecture is resolved. Local subscriptions (Phase 6) work as-is.

   **Implemented: Option A.** New files: `AwsNative_AppSync_Api.res`, `AwsNative_AppSync_ChannelNamespace.res` (Pulumi bindings); `AppSync_EventsApi.res` (creates Events API + `default` namespace, exposes `httpEndpoint`). `StateTopic_AppSync` and `EventLogSubscription_AppSync` updated: `~api` → `~eventsApi: AppSync_EventsApi.t`; endpoint from `eventsApi.api.dns.http`; IAM permission changed from `appsync:GraphQL` to `appsync:EventPublish`. Handler endpoint code simplified (no more `/graphql` stripping). Build clean — zero warnings.

1. **AppSync Events client availability in Lambda** *(moot if Option B from Q0 is chosen)*: Does `@aws-sdk/client-appsync-events` ship with the Lambda Node.js 22 runtime, or must it be bundled in the Reventless Lambda layer? Verify before first deploy if Option A from Q0 is chosen.

2. **Two WebSocket connections for clients** *(only applies if Q0 Option A is chosen)*: Source C uses the GraphQL WebSocket; Sources A and B would use the AppSync Events WebSocket. Should the client library abstract this into a single subscription interface? (Tracked in `reventless-client-transport.md`.) If Q0 Option B is chosen, all three sources use the GraphQL WebSocket — this question disappears.

3. **`AWSJSON` scalar in yoga**: Source A's `{Name}EventLogEvent` type uses `AWSJSON!`. This scalar is AppSync-specific and undefined in graphql-yoga. Phase 6 must either define a custom scalar or substitute `String` in the local SDL.

4. **Source B subscription filter — field name discovery**: The `makeSubscriptionResolver` call for Source B should pass `~subscriptionFilter` to enable per-entity filtering: only push to subscribers whose `ctx.args.id` matches the changed entity. Three options:

   **Option A — hardcode `"id"` (recommended)**: `QueryDbStorage_DynamoDb` always stores the partition key under the attribute name `"id"` (`hashKey: "id"->Pulumi.Input.make` in `Util_DynamoDb.makeTableArgs`). The `NewImage` unmarshalled from the DynamoDB stream therefore always has an `"id"` field regardless of what the state type names its `@id`-annotated field. The filter is therefore always:
   ```json
   { "filterGroup": [{ "filters": [{ "fieldName": "id", "operator": "eq", "value": { "ref": "ctx.args.id" } }] }] }
   ```
   This requires no schema introspection and no changes to `querySchemaEntry`. The plan's earlier example using `productId` as `fieldName` was wrong — the DynamoDB attribute is always `"id"`.

   **Option B — add `stateIdField: string` to `querySchemaEntry`**: Carry the `@id` field name through the pipeline from the PPX-generated spec into `querySchemaEntry`, then use it in both the SDL generator (for the filter arg name) and the resolver filter. This is accurate for exotic cases but adds coupling and is unnecessary given Option A.

   **Option C — introspect `stateSchema` at resolver-creation time**: The `@id` annotation metadata could be retrieved from the sury schema via `S.Metadata`. The PPX injects metadata onto the field, so in principle it could be recovered. This is fragile and undocumented; not recommended.

   **Recommendation: Option A.** Hardcode `"id"` as the `fieldName` in the subscription filter. Set this unconditionally when wiring `makeSubscriptionResolver` for Source B in Phase 4. No schema introspection needed.

5. **Source A opt-in**: Should `on{Name}EventLog_eventAppended` be generated for all plugins (and access-controlled via `@aws_auth`) or only when a plugin explicitly opts in? Currently generated for all plugins that have event logs.

6. **Phase 4 wiring point**: Where does `StateTopic_AppSync.make` get called? Options: (a) inside `QueryDbResolvers_AppSync.make` when `queryDbResources` contains a stream resource, (b) a new `Core_AppSync_Builder.res` that wraps all subscription infrastructure, (c) explicit call in each plugin stack. Option (a) is cleanest as it auto-activates when `QueryDbStorage_DynamoDbStream` is used.
