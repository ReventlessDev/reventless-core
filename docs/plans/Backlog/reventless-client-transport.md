# Plan: Reventless Client Transport — HTTP Command Endpoint and Event Catch-Up

## Context and Motivation

The `reventless-client` library (see [rescript-client-architecture.md](../../analysis/rescript-client-architecture.md)) uses three transport operations:

| Operation | What it does |
|-----------|-------------|
| `dispatch(command)` | Send a command via HTTP POST using the shared `Message.commandJson` format |
| `pullEvents(cursor)` | Fetch raw events since a cursor for offline-first reconnect sync |
| `subscribe()` | Receive live events via WebSocket (covered separately in `graphql-subscriptions-appsync.md`) |

This plan covers the first two — the non-subscription client transport primitives. They are independent of each other and independent of the subscription infrastructure.

**Why not GraphQL mutations for dispatch?** The client shares the same command types via spec packages and encodes `Message.commandJson` directly using sury schemas. Routing that through a GraphQL mutation resolver adds a translation step the client doesn't need. Direct HTTP dispatch also enables richer `Message.meta` (correlationId, client session ID) without mapping through GraphQL input types. GraphQL mutations remain available for third-party consumers who don't share the spec packages.

**Why not a pullEvents subscription?** Subscriptions deliver events in real time but don't support cursor-based historical catch-up. `pullEvents` is a one-shot query that returns all events since a given position — needed for offline-first reconnect and first-launch state bootstrap.

---

## Scope

| Capability | AWS (production) | In-Memory (local dev) |
|-----------|------------------|-----------------------|
| HTTP command dispatch | Lambda Function URL or API GW HTTP API | HTTP POST route on yoga server |
| `pullEvents(cursor)` catch-up query | AppSync GraphQL query → Lambda → DcbEventLog | GraphQL query → InMemory_Bus event history |

**Out of scope**: The `reventless-client` library itself. WebSocket subscriptions (see `graphql-subscriptions-appsync.md`). API Gateway WebSocket bidirectional transport (deferred). Offline-first SQLite WASM bindings.

**Dependency**: No dependency on the subscription plan. Can proceed independently. The in-memory event history (Phase 2 here) also enables `pullEvents` replay in tests.

---

## Phase 1 — HTTP Command Endpoint

**Target packages**: `reventless-aws`, `reventless-in-memory`

### 1.1 Why Lambda Function URL

Lambda Function URLs are the simplest option: no API Gateway needed, no additional routing infrastructure, deployable per plugin or as a shared handler. The URL is a stack output that the client configures at init time.

One Lambda Function URL per platform (routing by URL path within the Lambda) or per plugin — the trade-off is between simpler wiring (shared) and tighter blast radius (per plugin).

### 1.2 Request format

```
POST <commandEndpoint>/AddProduct
Content-Type: application/json

{
  "id": "prod-42",
  "meta": {
    "service": "online-shop-client",
    "time": "2026-04-16T10:00:00Z",
    "msgId": "msg-uuid",
    "correlationId": "session-uuid",
    "user": "martin@example.com"
  },
  "commandJson": { "TAG": "AddProduct", "productId": "prod-42", "name": "Widget", "price": 9.99 }
}
```

This is the same `Message.commandJson` envelope used internally by `CommandTopicChannel_SQS`. The Lambda validates the envelope shape and publishes to the existing CommandTopic.

### 1.3 Response

Synchronous acceptance acknowledgement (command placed in SQS FIFO):
```json
{ "success": true, "msgId": "msg-uuid" }
```

Rejection (envelope malformed or command decode failed):
```json
{ "success": false, "error": "Invalid command envelope" }
```

The response confirms the command was *accepted into the queue*, not that the aggregate processed it. Confirmed outcomes arrive via subscription (Source C) or state query.

### 1.4 AWS: `CommandHttpHandler_Lambda.res`

**New file**: `reventless-aws/src/adapter/CommandHttp/CommandHttpHandler_Lambda.res`

**Deploy-time resources**:
- `aws.lambda.Function` — receives HTTP POST, validates `Message.commandJson`, publishes to CommandTopic SQS FIFO
- `aws.lambda.FunctionUrl` — public HTTPS endpoint (auth: IAM or NONE, configurable)
- IAM policy: `sqs:SendMessage` on the CommandTopic queue ARN

**Runtime handler**:
```javascript
export async function handler(event) {
  const body = JSON.parse(event.body);
  const { id, meta, commandJson } = body;
  if (!id || !meta || !commandJson) {
    return { statusCode: 400, body: JSON.stringify({ success: false, error: "Invalid command envelope" }) };
  }
  const channelName = extractChannelFromPath(event.rawPath);
  await sqs.sendMessage({ QueueUrl: queueUrl, MessageBody: JSON.stringify(body), MessageGroupId: id });
  return { statusCode: 200, body: JSON.stringify({ success: true, msgId: meta.msgId }) };
}
```

**Stack output**: Export `commandEndpoint` as a Pulumi stack output alongside `id`, `version`, and component dicts.

### 1.5 In-memory: `CommandHttpHandler_InMemory.res`

**New file**: `reventless-in-memory/src/adapter/CommandHttp/CommandHttpHandler_InMemory.res`

graphql-yoga (based on `@whatwg-node/server`) supports custom HTTP routes alongside GraphQL. The yoga server at port 4000 adds a `POST /commands/*` handler that calls `InMemory_Bus.dispatchCommand` directly:

```rescript
let register = (server, bus) => {
  server->addRoute("POST", "/commands/*", async req => {
    let body = await req->readJsonBody
    let channelName = req->extractChannelName  // URL path -> CommandTopic channel name
    let _ = await bus->dispatchCommand(channelName, body)
    Response.json({success: true})
  })
}
```

The bus is already transport-agnostic — `dispatchCommand` is called identically whether the command came from a GraphQL mutation resolver or this HTTP handler.

### 1.6 Steps

- [ ] Create `CommandHttpHandler_Lambda.res` — Lambda Function URL Pulumi resource + IAM policy
- [ ] Create runtime Lambda handler: validate envelope, publish to CommandTopic SQS FIFO
- [ ] Wire `CommandHttpHandler_Lambda` into plugin deployment
- [ ] Export `commandEndpoint` as Pulumi stack output
- [ ] Create `CommandHttpHandler_InMemory.res` — HTTP POST route on yoga server
- [ ] Wire into `Platform_InMemory.res` alongside existing yoga GraphQL server setup
- [ ] Integration test: HTTP POST dispatches command via both AWS and in-memory transports

---

## Phase 2 — `pullEvents` Catch-Up Query

**Target packages**: `reventless-core`, `reventless-aws`, `reventless-in-memory`

### 2.1 Use cases (from rescript-client-architecture.md §1.4, §3.5)

The offline-first client uses `pullEvents` in two scenarios:
- **First launch**: Fetch all events from cursor `"0"`, project into SQLite state tables
- **Reconnect after offline**: Fetch events since last confirmed cursor, rebase pending local events

This is a read against the raw DcbEventLog (not the projected QueryDb state). It returns events in position order, paginated by cursor.

### 2.2 Schema

```graphql
# Added to type Query { } in the plugin's SDL fragment
pullCatalogEvents(cursor: String, scope: String, limit: Int): CatalogEventBatch!

type CatalogEventBatch {
  events: [CatalogRawEvent!]!
  cursor: String!    # position of the last returned event (use as next cursor)
  hasMore: Boolean!
}

type CatalogRawEvent {
  position: String!
  eventType: String!
  payload: AWSJSON!
  tags: [EventTag!]!
}

type EventTag {
  key: String!
  value: String!
}
```

The `scope` argument is an optional DCB tag filter (e.g., `"productId:prod-42"`). If omitted, returns all events. DCB-based plugins only — aggregate-based plugins use per-aggregate streams that don't map to a global cursor.

### 2.3 AWS resolver

AppSync resolver → Lambda → `DcbEventLog_Adapter.operations.read(~query=scope, ~after=cursor)`. The Lambda paginates to `limit` events and serializes to `CatalogEventBatch`.

**New file**: `reventless-aws/src/adapter/DcbEventLog/PullEvents_AppSync.res`

This follows the same Lambda + AppSync resolver pattern as existing QueryDb resolvers.

### 2.4 In-memory: event history in `InMemory_Bus`

The in-memory bus currently publishes events fire-and-forget (PubSub fan-out to subscribers). Add a retained history for `pullEvents` support — approximately 50 lines:

```rescript
// Extension to InMemory_Bus
type historicEvent = {
  position: string,
  eventType: string,
  data: JSON.t,
  tags: array<DcbTag.tag>,
}

let eventHistory: ref<array<historicEvent>> = ref([])
let eventHistoryPosition: ref<int> = ref(0)

// Appended to every publishEvent call:
eventHistoryPosition := eventHistoryPosition.contents + 1
eventHistory := eventHistory.contents->Array.concat([{
  position: eventHistoryPosition.contents->Int.toString,
  eventType, data, tags,
}])

let getEventsAfterCursor = (~cursor: option<string>, ~limit: option<int>) =>
  eventHistory.contents->Array.filter(e =>
    cursor->Option.mapOr(true, c => e.position->Int.fromStringOrThrow > c->Int.fromStringOrThrow)
  )->Array.slice(~start=0, ~end=limit->Option.getOr(100))
```

The `pullEvents` yoga query resolver calls `getEventsAfterCursor` and returns the result in `CatalogEventBatch` format.

### 2.5 Steps

- [ ] Add `pullCatalogEvents` SDL field to plugin query fragment (alongside existing query fields)
- [ ] Define `CatalogEventBatch`, `CatalogRawEvent`, `EventTag` types in SDL
- [ ] Create `PullEvents_AppSync.res` — AppSync resolver → Lambda → `DcbEventLog_Adapter.operations.read`
- [ ] Wire into `Core_AppSync_Builder.res` alongside existing query resolvers
- [ ] Add `eventHistory` array + `getEventsAfterCursor` to `InMemory_Bus`
- [ ] Create `pullEvents` yoga query resolver using `getEventsAfterCursor`
- [ ] Integration test: `pullEvents(cursor: "0")` returns events in position order

---

## File Map

### New files

| Package | File | Phase | Purpose |
|---------|------|-------|---------|
| `reventless-aws` | `src/adapter/CommandHttp/CommandHttpHandler_Lambda.res` | 1 | Lambda Function URL + IAM (deploy-time) |
| `reventless-in-memory` | `src/adapter/CommandHttp/CommandHttpHandler_InMemory.res` | 1 | HTTP POST route on yoga (in-memory) |
| `reventless-aws` | `src/adapter/DcbEventLog/PullEvents_AppSync.res` | 2 | AppSync resolver → Lambda → DcbEventLog read |

### Modified files

| Package | File | Phase | Change |
|---------|------|-------|--------|
| `reventless-aws` | `src/core/Core_AppSync_Builder.res` | 2 | Wire `pullEvents` resolver |
| `reventless-in-memory` | `src/InMemory_Bus.res` | 2 | Add event history + `getEventsAfterCursor` |
| `reventless-in-memory` | `src/Platform.res` | 1, 2 | Wire HTTP handler + `pullEvents` yoga resolver |

---

## Client transport wiring (rescript-client-architecture.md)

The operations in this plan, combined with subscriptions from `graphql-subscriptions-appsync.md`, give the client library its full transport surface:

| Operation | Transport | Plan |
|-----------|-----------|------|
| `dispatch(command)` | HTTP POST to `commandEndpoint` | This plan, Phase 1 |
| `pullEvents(cursor)` | GraphQL query `pullCatalogEvents` | This plan, Phase 2 |
| `subscribe()` (Live mode) | AppSync / yoga WebSocket | `graphql-subscriptions-appsync.md` |
| `query state` | GraphQL query (existing) | Already implemented |

The client's `transportConfig`:
```rescript
type transportConfig =
  | Local({url: string})       // yoga: POST /commands/* + WS at same host
  | Aws({
      commandUrl: string,      // Lambda Function URL
      graphqlUrl: string,      // AppSync HTTPS (queries + pullEvents)
      realtimeUrl: string,     // AppSync WSS (subscriptions)
    })
```

---

## Open Questions

1. **Lambda Function URL auth**: IAM auth (SigV4 signed by Cognito Identity Pool credentials) is correct for the ReScript client. Should a NONE-auth variant be provided for development/internal use? Recommend: IAM by default, configurable.

2. **Shared vs. per-plugin command URL**: One Lambda Function URL per platform (with path-based routing) vs. one per plugin. Per-plugin is more isolated; shared is simpler. Recommend: shared with path routing initially.

3. **`pullEvents` scope format**: Should `scope` be a raw DCB tag filter string (`"productId:prod-42"`) or a structured type? Structured is safer but requires more SDL. Start with a string and parse server-side.

4. **Aggregate EventLog `pullEvents`**: This plan covers DCB-based plugins only. Aggregate-based plugins use per-aggregate streams — supporting `pullEvents` for them requires a different query strategy (per-aggregate replay). Defer until needed.

---

## Checklist

### Phase 1 — HTTP command endpoint
- [ ] `CommandHttpHandler_Lambda.res` — Lambda Function URL + IAM policy
- [ ] Runtime Lambda handler: validate envelope, publish to CommandTopic SQS FIFO
- [ ] `commandEndpoint` exported as Pulumi stack output
- [ ] `CommandHttpHandler_InMemory.res` — HTTP POST route on yoga server
- [ ] Wired into `Platform_InMemory.res`
- [ ] Integration test: HTTP POST dispatches command via both transports

### Phase 2 — `pullEvents` query
- [ ] `pullCatalogEvents` SDL field in plugin query fragment
- [ ] `CatalogEventBatch`, `CatalogRawEvent`, `EventTag` types in SDL
- [ ] `PullEvents_AppSync.res` — AppSync resolver → Lambda → `DcbEventLog_Adapter.operations.read`
- [ ] Wired into `Core_AppSync_Builder.res`
- [ ] `eventHistory` + `getEventsAfterCursor` added to `InMemory_Bus`
- [ ] `pullEvents` yoga query resolver created
- [ ] Integration test: `pullEvents(cursor: "0")` returns events in position order
