# ReScript Client Architecture: Sync Strategies for Reventless

## Executive Summary

This analysis explores how a ReScript-based React client can integrate with a Reventless backend using two distinct sync strategies that the app developer chooses between:

1. **Online-First**: The client reads current state from the backend's QueryDb, receives live events via GraphQL subscription, and applies the same projections as the server to update local state. No persistent local event storage is needed — the backend is the source of truth, and the client re-fetches state on reconnect. Commands are sent to the backend and the UI waits for the resulting event (with optional optimistic UI).

2. **Offline-First**: The client always writes to a local event log first (both online and offline), projects events locally, and synchronizes with the backend asynchronously. This is the same architecture as LiveStore — the client has its own source of truth and syncs as a peer.

Both strategies reuse the same backend projection functions (`project`, `decide`, `reduce`), the same event types, command types, and state types, and the same transport layer. The difference is in where state lives, whether events are stored locally, and how the client behaves when disconnected.

## 1. Shared Architecture: What Both Strategies Have in Common

### 1.1 Reusing Backend Code on the Client

Using the DCB online shop example (`examples/online-shop-dcb/`) as reference, the following backend functions are **pure ReScript** that compile to plain JavaScript with no server-side dependencies:

| Backend Component | Example | Client Reuse | Dependencies |
|-------------------|---------|-------------|--------------|
| `@schema type event` (event types + sury schemas) | `CatalogEventLog.event`, `OrderingEventLog.event` | Direct reuse | sury runtime only |
| `@schema type command` (command types + sury schemas) | `AddProduct.command`, `PlaceOrder.command`, `ChangeProductPrice.command` | Direct reuse | sury runtime only |
| `@schema type state` (projected state types) | `ProductsView.state`, `OrdersView.state`, `CustomersView.state` | Direct reuse | sury runtime only |
| `StateViewSlice.project(state, event)` | `ProductsView.project`, `OrdersView.project`, `CategoriesView.project` | Direct reuse | Event types, state types |
| `StateChangeSlice.decide(model, command)` | `AddProduct.decide`, `PlaceOrder.decide`, `ChangeProductName.decide` | Direct reuse | Event types, command types |
| `StateChangeSlice.reduce(model, event)` | `AddProduct.reduce`, `PlaceOrder.reduce` | Direct reuse | Event types, decision model type |
| `Projection.action` type | `Set(productId, state)`, `Update(productId, f)` | Direct reuse | None (algebraic type) |
| `Projection.handleAction` | — | **Cannot reuse** | QueryDb storage operations |
| Extension/EP mappings | `ProductsExtensionPointMapping`, `OrdersExtension` | **Cannot reuse** | Cross-plugin infrastructure |
| `EventCollector`, `EventTopic` | — | **Cannot reuse** | AWS infrastructure (SQS, SNS) |

The command types are essential on the client: the client needs `AddProduct.command` to construct commands for dispatch (both strategies), `AddProduct.commandSchema` to encode `Message.commandJson` for direct HTTP POST (section 7), and the command + error types for `decide()` in optimistic UI prediction (online-first) and local validation (offline-first).

The pure functions (project, decide, reduce) have no I/O, no async, no infrastructure coupling. They take events in and return actions/decisions out.

For example, `ProductsView.project` from the Catalog plugin is a pure function:

```rescript
// catalog/src/Product/StateViewSlice/ProductsView.res — runs on server AND client
let project = (_, event) =>
  switch event {
  | ProductAdded({productId, name, description, price}) =>
    [Set(productId, {productId, name, description, price})]
  | ProductNameChanged({productId, name}) =>
    [Update(productId, state => {...state, name})]
  | ProductPriceChanged({productId, price}) =>
    [Update(productId, state => {...state, price})]
  | ProductDescriptionChanged({productId, description}) =>
    [Update(productId, state => {...state, description})]
  | _ => []
  }
```

And `AddProduct.decide` is equally pure:

```rescript
// catalog/src/Product/StateChangeSlice/AddProduct.res — runs on server AND client
let decide = (model, command) =>
  switch command {
  | AddProduct({productId, name, description, price}) =>
    if model.exists {
      Error(ProductAlreadyExists)
    } else {
      Ok([ProductAdded({productId, name, description, price})])
    }
  }
```

### 1.2 Shared Package Structure

Currently in the DCB online shop, event types, command types, state types, projections, and decision logic live inside the plugin packages (`catalog/`, `ordering/`). To reuse them on the client, the pure types and functions need to be extracted into shared spec packages that both server and client can depend on.

The existing structure already has spec packages (`catalog-spec/`, `ordering-spec/`) for extension point types. These can be extended to hold the portable code:

```
examples/online-shop-dcb/
  catalog-spec/               <- EXISTING: extension point types
    src/
      ProductsExtensionPoint.res
      CatalogEvents.res       <- MOVE HERE: @schema type event from CatalogEventLog
      ProductsView.res        <- MOVE HERE: @schema type state, project(state, event) -> actions
      ProductDemandView.res   <- MOVE HERE: @schema type state, project(state, event) -> actions
      CategoriesView.res      <- MOVE HERE: @schema type state, project(state, event) -> actions
      AddProduct.res          <- MOVE HERE: @schema type command, @schema type error, decide, reduce
      ChangeProductName.res   <- MOVE HERE: @schema type command, @schema type error, decide, reduce
      ChangeProductPrice.res  <- MOVE HERE: @schema type command, @schema type error, decide, reduce
      ChangeProductDescription.res
      AddCategory.res         <- MOVE HERE: @schema type command, @schema type error, decide, reduce
      RenameCategory.res
      ArchiveCategory.res

  ordering-spec/              <- EXISTING: extension point types
    src/
      OrdersExtensionPoint.res
      OrderingEvents.res      <- MOVE HERE: @schema type event from OrderingEventLog
      OrdersView.res          <- MOVE HERE: @schema type state, project(state, event) -> actions
      CustomersView.res       <- MOVE HERE: @schema type state, project(state, event) -> actions
      AvailableProductsView.res <- MOVE HERE: @schema type state, project(state, event) -> actions
      PlaceOrder.res          <- MOVE HERE: @schema type command, @schema type error, decide, reduce
      ShipOrder.res           <- MOVE HERE: @schema type command, @schema type error, decide, reduce
      CancelOrder.res         <- MOVE HERE: @schema type command, @schema type error, decide, reduce
      RegisterCustomer.res    <- MOVE HERE: @schema type command, @schema type error, decide, reduce
      ChangeEmail.res
      ChangeAddress.res
      DeactivateCustomer.res

  catalog/                    <- SERVER ONLY: plugin wiring, EP mappings, extensions
  ordering/                   <- SERVER ONLY: plugin wiring, EP mappings, automation
  online-shop-dcb/            <- SERVER ONLY: platform assembly

  online-shop-client/         <- NEW: ReScript + React client app
```

The spec packages:
- Have no dependency on `reventless-core` or `reventless-aws`
- Depend only on `sury` (for `@schema` serialization of event, command, and state types) and `reventless-spec` (for `Projection.action` type)
- Compile to JavaScript that runs in both Node.js and browser
- Are consumed by both the server-side plugin builders AND the client-side app

The server plugin packages (`catalog/`, `ordering/`) import from their spec packages and wire the pure functions to infrastructure (CommandTopic handlers, EventCollector subscriptions, QueryDb storage). The client imports the same spec packages and uses the same command types to construct and encode commands for dispatch, the same event types to deserialize incoming events, the same state types for the projected state store, and the same `decide`/`reduce`/`project` functions for validation and projection.

### 1.3 Client-Side Projection Executor

The `project` function returns `Projection.action` values. On the server, `Projection.handleAction` executes these against DynamoDB via QueryDb. On the client, a thin adapter executes them against local state — this adapter is shared by both strategies:

```rescript
// Client-side action executor (~50 lines, shared by both strategies)
let applyAction = (store: clientStore, action: Projection.action<string, 'state>) =>
  switch action {
  | Set(id, state) => store->put(id, state)
  | Update(id, f) =>
    switch store->get(id) {
    | Some(current) => store->put(id, f(current))
    | None => ()
    }
  | Delete(id) => store->remove(id)
  | Create(id, state) => store->put(id, state)
  | Ignore => ()
  }
```

For example, when `ProductsView.project` returns `[Set("prod-1", {productId: "prod-1", name: "Widget", description: "A widget", price: 9.99})]`, the client-side executor calls `store->put("prod-1", ...)` — whether that writes to an in-memory map (online-first) or a SQLite table (offline-first).

Similarly, `CategoriesView.project` returning `[Update("cat-1", state => {...state, archived: true})]` triggers a read-modify-write on the local store via `store->get("cat-1")` then `store->put("cat-1", updatedState)`.

The difference between strategies is what backs `clientStore`: an in-memory map (online-first) or SQLite tables (offline-first).

### 1.4 Transport Layer

Both strategies use the same transport layer, which combines multiple protocols optimized for each direction of communication. Section 7 analyzes the transport options in detail; here we summarize the operations:

**Query (catch-up pull — used by offline-first for sync, optionally by online-first):**
```graphql
query PullEvents($cursor: Int!, $scope: String!, $limit: Int) {
  pullEvents(cursor: $cursor, scope: $scope, limit: $limit) {
    events {
      globalSequence
      eventType
      payload
    }
    cursor
    hasMore
  }
}
```

**Query (current state — used by online-first for initial load and reconnection):**
```graphql
# Catalog plugin views
query GetCatalogState {
  products { productId name description price }
  categories { categoryId name archived }
  productDemand { productId name orderCount }
}

# Ordering plugin views
query GetOrderingState {
  orders { orderId customerId productIds status }
  customers { customerId email address deactivated }
  availableProducts { productId name price }
}
```

**Command dispatch (HTTP POST with `Message.commandJson` — see section 7):**
```
POST /commands/{pluginName}/{sliceName}
Content-Type: application/json

{
  "id": "prod-42",
  "meta": { "service": "online-shop-client", "time": "...", "msgId": "...", "user": "..." },
  "commandJson": { "TAG": "AddProduct", "productId": "prod-42", "name": "Widget", ... }
}

Response: { "success": true } or { "success": false, "error": "ProductAlreadyExists" }
```

For offline-first batch sync, multiple commands can be sent in a single request:
```
POST /commands/batch
Content-Type: application/json

{
  "commands": [ ... array of Message.commandJson ... ],
  "cursor": 42
}

Response: { "success": true, "newCursor": 45, "rejected": [] }
```

Note: GraphQL mutations remain available as an alternative command transport, especially for third-party API consumers who don't share the ReScript spec packages.

**Subscription (live tail):**
```graphql
subscription NewEvents($scope: String!) {
  newEvents(scope: $scope) {
    events {
      globalSequence
      eventType
      payload
    }
    cursor
  }
}
```

### 1.5 AppSync Compatibility

All operations work with AWS AppSync:
- **Query**: Standard AppSync resolver -> Lambda -> DcbEventLog query or QueryDb read
- **Mutation**: AppSync resolver -> Lambda -> Sync API validate + append
- **Subscription**: AppSync real-time endpoint (WebSocket). Events pushed via EventTopic -> Lambda -> AppSync Events HTTP API -> subscribed clients.

This reuses the existing AppSync deployment and the planned subscription infrastructure (see `docs/plans/Backlog/graphql-subscriptions-realtime.md`).

## 2. Online-First Strategy

### 2.1 Architecture Overview

```
+---------------------------------------------------------+
|  Browser (ReScript + React)                              |
|                                                          |
|  User Action                                             |
|       |                                                  |
|       v                                                  |
|  Encode Message.commandJson (shared sury schema)         |
|       |                                                  |
|       +---> [Optimistic UI: apply locally immediately]   |
|       |                                                  |
|       v                                                  |
|  Send command via HTTP POST                              |
|       |                                                  |
|       v                                                  |
|  Receive event via AppSync WebSocket subscription        |
|       |                                                  |
|       v                                                  |
|  Projection.project()  <- reused from backend            |
|       |                                                  |
|       v                                                  |
|  In-Memory State Store (Map / Record)                    |
|       |                                                  |
|       v                                                  |
|  React UI (reactive state)                               |
|                                                          |
|  +--------------------+                                  |
|  | Connection Monitor |                                  |
|  | online/offline     |                                  |
|  +--------------------+                                  |
+---------------------------------------------------------+
           HTTP POST |           ^ AppSync WebSocket
          (commands) |           | (events)
                     v           |
+---------------------------------------------------------+
|  Reventless Backend (AWS)                                |
|                                                          |
|  Lambda Function URL / API Gateway                       |
|    receive commandJson -> CommandTopic (SQS FIFO)        |
|                                                          |
|  GraphQL API (AppSync)                                   |
|    query: getCurrentState()  (initial load + reconnect)  |
|    subscription: newEvents() (live updates)              |
|       |                                                  |
|       v                                                  |
|  DcbEventLog / QueryDb / EventTopic                      |
+---------------------------------------------------------+
```

### 2.2 Lifecycle

**Startup:**
1. Connect to GraphQL endpoint
2. Query current state from QueryDb (fast — returns projected state, not events)
3. Open GraphQL subscription for live events, starting from the cursor returned with the state query
4. Render UI from received state

**User action (standard flow — example: adding a product to the catalog):**
1. User fills in the "Add Product" form and clicks submit
2. Client encodes `Message.commandJson` using the shared `AddProduct.commandSchema` and sends via HTTP POST to `/commands/catalog/AddProduct`
3. Backend Lambda receives the `commandJson`, publishes to CommandTopic SQS FIFO
4. Aggregate handler runs `AddProduct.decide(model, AddProduct(...))` — checks `model.exists == false`, appends `ProductAdded` event, publishes to EventTopic
5. Client receives `ProductAdded({productId: "prod-42", name: "Widget", description: "A fine widget", price: 9.99})` via AppSync subscription
6. Client applies `ProductsView.project(None, ProductAdded(...))` -> `[Set("prod-42", {productId: "prod-42", name: "Widget", description: "A fine widget", price: 9.99})]`
7. React re-renders — the new product appears in the product list

**User action (optimistic UI flow — example: placing an order):**
1. User clicks "Place Order"
2. Client runs `PlaceOrder.decide(model, PlaceOrder({orderId: "ord-7", customerId: "cust-1", productIds: ["prod-42"]}))` locally to predict the event
3. Client immediately applies `OrdersView.project(None, OrderPlaced(...))` -> `[Set("ord-7", {orderId: "ord-7", customerId: "cust-1", productIds: ["prod-42"], status: "placed"})]`
4. React re-renders with the new order (instant)
5. Client sends `Message.commandJson` via HTTP POST to `/commands/ordering/PlaceOrder`
6. HTTP response returns `{success: true}` — command accepted. Confirmed `OrderPlaced` event arrives via subscription, reconciles with provisional state (no visible change — prediction was correct)
7. If HTTP response returns `{success: false, error: "OrderAlreadyPlaced"}` — client rolls back the provisional order immediately, without waiting for a subscription event

**Disconnection:**
1. Subscription drops, connection monitor detects offline state
2. UI shows "disconnected" indicator
3. User actions are disabled or queued (see section 2.4)
4. No local event storage needed — state stays in memory as last-known-good

**Reconnection:**
1. Connection restored
2. Re-query current state from QueryDb (full state refresh)
3. Re-open subscription from new cursor
4. Replace in-memory state with fresh server state
5. Resume normal operation

### 2.3 In-Memory State Store

Online-first does not need persistent storage. State lives in memory:

```rescript
module StateStore = {
  type t<'state> = {
    mutable data: Map.t<string, 'state>,
    mutable cursor: int,
    mutable listeners: array<unit => unit>,
  }

  let make = () => {
    data: Map.make(),
    cursor: 0,
    listeners: [],
  }

  let get = (store, id) => store.data->Map.get(id)
  let put = (store, id, state) => {
    store.data->Map.set(id, state)
    store.listeners->Array.forEach(f => f())
  }
  let remove = (store, id) => {
    store.data->Map.delete(id)->ignore
    store.listeners->Array.forEach(f => f())
  }
  let subscribe = (store, listener) => {
    store.listeners->Array.push(listener)
  }
}
```

This is intentionally simple. No SQLite, no OPFS, no IndexedDB. The backend's QueryDb is the durable store.

### 2.4 Offline Behavior

When the client is offline, it has several options for handling user actions:

**Option A: Disable mutations (simplest)**
- Show "offline" indicator
- Disable buttons/forms that would trigger commands
- State remains visible but read-only
- On reconnect: full state refresh

**Option B: Queue commands (moderate complexity)**
- Accept user actions into an in-memory command queue
- Show "pending" state on queued actions
- On reconnect: send queued commands, process results
- Risk: commands may fail validation against state that changed while offline

**Option C: Optimistic offline (more complex)**
- Apply provisional events locally (like optimistic UI, but unbounded duration)
- Queue the corresponding commands
- On reconnect: send queued commands, reconcile
- Risk: more divergence to reconcile

Option A is recommended as the default for online-first — it's honest about the system's capabilities and avoids complex reconciliation. Option B can be added for specific high-value interactions (e.g., adding items to a cart).

### 2.5 Optimistic UI

Optimistic UI applies a provisional state change before the server confirms it. This reduces perceived latency while online.

**Example: Changing a product's price**

Without optimistic UI, the user changes the price from 9.99 to 14.99 and waits ~100ms for the server round-trip before the UI updates. With optimistic UI:

```rescript
// 1. Predict the event using the shared decide function
let prediction = ChangeProductPrice.decide(
  {exists: true, currentPrice: 9.99},  // decision model from event stream
  ChangeProductPrice({productId: "prod-42", price: 14.99})
)
// -> Ok([ProductPriceChanged({productId: "prod-42", price: 14.99})])

// 2. Apply projection locally with predicted event
let actions = ProductsView.project(
  Some({productId: "prod-42", name: "Widget", description: "A fine widget", price: 9.99}),
  ProductPriceChanged({productId: "prod-42", price: 14.99})
)
// -> [Update("prod-42", state => {...state, price: 14.99})]

// 3. UI updates instantly. Command sent to server in background.
// 4. On confirmed event via subscription: reconcile (no-op, prediction was correct)
// 5. On rejection: roll back to price: 9.99
```

The optimistic update tracker manages pending predictions:

```rescript
module OptimisticUpdate = {
  type provisional<'state> = {
    entityId: string,
    originalState: option<'state>,
    commandId: string,
  }

  type t<'state> = {
    mutable pending: array<provisional<'state>>,
  }

  // Apply optimistic update before sending command
  let apply = (tracker, store, ~entityId, ~event, ~project) => {
    let original = store->StateStore.get(entityId)
    let actions = project(original, event)
    actions->Array.forEach(action => applyAction(store, action))
    tracker.pending->Array.push({entityId, originalState: original, commandId: entityId})
  }

  // Confirm: server event arrived matching our prediction
  let confirm = (tracker, _store, ~commandId) => {
    tracker.pending = tracker.pending->Array.filter(p => p.commandId != commandId)
  }

  // Reject: server rejected our command, roll back
  let rollback = (tracker, store, ~commandId) => {
    switch tracker.pending->Array.find(p => p.commandId == commandId) {
    | Some(provisional) =>
      switch provisional.originalState {
      | Some(state) => store->StateStore.put(provisional.entityId, state)
      | None => store->StateStore.remove(provisional.entityId)
      }
      tracker.pending = tracker.pending->Array.filter(p => p.commandId != commandId)
    | None => ()
    }
  }
}
```

When a server event arrives that wasn't predicted by an optimistic update (e.g., another user changed the same product), it's applied normally. When it matches a pending optimistic update, the provisional state is confirmed (no visible change). When a command is rejected, the rollback restores the original state.

For more complex scenarios where multiple optimistic updates are in flight and may interact (e.g., a user changes a product's name and price in quick succession), a full rollback-and-replay approach is needed: roll back all pending optimistic updates, apply the server event, then re-apply remaining optimistic updates. This converges toward the offline-first approach's rebase mechanism.

## 3. Offline-First Strategy

### 3.1 Architecture Overview

```
+---------------------------------------------------------+
|  Browser (ReScript + React)                              |
|                                                          |
|  User Action                                             |
|       |                                                  |
|       v                                                  |
|  StateChangeSlice.decide()  <- reused from backend       |
|       |                                                  |
|       v                                                  |
|  Local Event Log (SQLite WASM / OPFS)                    |
|       |                                                  |
|       v                                                  |
|  Projection.project()  <- reused from backend            |
|       |                                                  |
|       v                                                  |
|  Client State Store (SQLite tables)                      |
|       |                                                  |
|       v                                                  |
|  React UI (reactive queries)                             |
|                                                          |
|  +----------------------+                                |
|  | Sync Engine          |                                |
|  |  push: mutation -------->                             |
|  |  pull: query <--------                                |
|  |  subscribe <----------                                |
|  +----------------------+                                |
+---------------------------------------------------------+
                    |           ^
                    v           |
+---------------------------------------------------------+
|  Reventless Backend (AWS)                                |
|                                                          |
|  GraphQL API (AppSync)                                   |
|    query: pullEvents(cursor)                             |
|    subscription: newEvents(scope)                        |
|    mutation: pushEvents(batch)                           |
|       |                                                  |
|       v                                                  |
|  DcbEventLog / EventTopic / QueryDb                      |
+---------------------------------------------------------+
```

### 3.2 Key Principle: Always Local

The client always writes events to the local event log first, always projects locally for immediate UI updates, and syncs with the backend asynchronously. Whether the network is available doesn't change the code path.

- **Zero latency UI updates**: Every user action takes effect in <1ms (local SQLite write + projection)
- **No mode switching**: Same code path online and offline
- **Resilient**: Network failures don't degrade UX
- **Local event log is the client's source of truth**

### 3.3 Client-Side Event Log Storage

The client needs a durable, append-only event log in the browser:

| Storage | Write Latency | Query | Persistence | Browser Support |
|---------|--------------|-------|-------------|-----------------|
| **SQLite WASM + OPFS** | ~1ms | Full SQL | Durable | Chrome/Edge full, Firefox progressing, Safari limited |
| **SQLite WASM + IndexedDB** | ~3ms | Full SQL | Durable (evictable) | Universal |
| **IndexedDB (raw)** | ~3ms | Key-value + indexes | Durable (evictable) | Universal |

**Recommendation: SQLite WASM with OPFS (primary) + IndexedDB (fallback).**

SQLite is the best fit because:
1. SQL queries over events (sequence number, event type, cursor ranges) are natural
2. ~1ms writes via OPFS, ideal for an event log
3. Same approach as LiveStore, validating the architecture
4. Projected state tables can live in the same database
5. Small binding surface (~15 functions)

**Schema (matching DCB online shop StateViewSlice state types):**

```sql
-- Event log (append-only, stores CatalogEventLog + OrderingEventLog events)
CREATE TABLE events (
  local_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  global_sequence INTEGER,          -- null until confirmed by server
  event_type TEXT NOT NULL,         -- e.g. "ProductAdded", "OrderPlaced"
  payload TEXT NOT NULL,            -- JSON-encoded event payload
  client_id TEXT NOT NULL,
  status TEXT DEFAULT 'pending',    -- pending | confirmed | rejected
  created_at TEXT NOT NULL
);

CREATE INDEX idx_events_status ON events(status);
CREATE INDEX idx_events_global ON events(global_sequence);

-- Projected state tables (derived from events via StateViewSlice.project, rebuildable)

-- From ProductsView.project (Catalog plugin)
CREATE TABLE products (
  product_id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT NOT NULL,
  price REAL NOT NULL
);

-- From CategoriesView.project (Catalog plugin)
CREATE TABLE categories (
  category_id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  archived INTEGER DEFAULT 0
);

-- From ProductDemandView.project (Catalog plugin)
CREATE TABLE product_demand (
  product_id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  order_count INTEGER DEFAULT 0
);

-- From OrdersView.project (Ordering plugin)
CREATE TABLE orders (
  order_id TEXT PRIMARY KEY,
  customer_id TEXT NOT NULL,
  product_ids TEXT NOT NULL,         -- JSON array of product IDs
  status TEXT NOT NULL               -- "placed" | "shipped" | "cancelled"
);

-- From CustomersView.project (Ordering plugin)
CREATE TABLE customers (
  customer_id TEXT PRIMARY KEY,
  email TEXT NOT NULL,
  address TEXT NOT NULL,
  deactivated INTEGER DEFAULT 0
);

-- From AvailableProductsView.project (Ordering plugin)
CREATE TABLE available_products (
  product_id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  price REAL NOT NULL
);
```

### 3.4 Component Architecture

```
+--------------------------------------------------------+
|  Reventless Client Library (ReScript package)           |
|                                                         |
|  +--------------+  +--------------+  +--------------+  |
|  | EventLog     |  | Projector    |  | SyncEngine   |  |
|  |              |  |              |  |              |  |
|  | append()     |  | project()    |  | push()       |  |
|  | getAfter()   |  | rebuild()    |  | pull()       |  |
|  | getPending() |  | applyAction()|  | rebase()     |  |
|  | confirm()    |  |              |  | subscribe()  |  |
|  | reject()     |  |              |  |              |  |
|  +------+-------+  +------+-------+  +------+-------+  |
|         |                 |                  |          |
|         v                 v                  v          |
|  +--------------------------------------------------+  |
|  | SQLite WASM (OPFS / IndexedDB)                    |  |
|  |  - events table (append-only log)                 |  |
|  |  - projected state tables (derived)               |  |
|  +--------------------------------------------------+  |
|                                                         |
|  +--------------+  +--------------+                     |
|  | CommandHandler|  | ReactHooks   |                     |
|  | dispatch()   |  | useQuery()   |                     |
|  | validate()   |  | useDispatch()|                     |
|  +--------------+  +--------------+                     |
+--------------------------------------------------------+
```

**EventLog** — Manages the local append-only event log. Stores `CatalogEventLog.event` and `OrderingEventLog.event` values:
```rescript
module EventLog = {
  let append: (db, event) => promise<localSequence>
  let getAfterCursor: (db, ~cursor: int) => promise<array<event>>
  let getPending: db => promise<array<event>>
  let confirmBatch: (db, ~localSequences: array<int>, ~globalSequences: array<int>) => promise<unit>
  let rejectBatch: (db, ~localSequences: array<int>) => promise<unit>
}
```

**SyncEngine** — Push/pull synchronization:
```rescript
module SyncEngine = {
  type status = Online | Offline | Syncing

  let push: (db, ~graphqlClient: client) => promise<pushResult>
  let pull: (db, ~graphqlClient: client, ~cursor: int) => promise<array<event>>
  let subscribe: (db, ~graphqlClient: client, ~scope: string) => subscription
  let rebase: (db, ~serverEvents: array<event>, ~pendingEvents: array<event>) => promise<unit>
}
```

**CommandHandler** — Validates commands locally using the shared `decide` function. Uses the same `decide` and `reduce` from `AddProduct`, `PlaceOrder`, etc.:
```rescript
module CommandHandler = {
  let dispatch: (
    db,
    ~command: command,
    ~reduce: (decisionModel, event) => decisionModel,
    ~decide: (decisionModel, command) => Result.t<array<event>, error>,
    ~initialModel: decisionModel,
  ) => promise<Result.t<array<event>, error>>
  // Example: dispatch(db,
  //   ~command=AddProduct({productId: "prod-42", name: "Widget", description: "...", price: 9.99}),
  //   ~reduce=AddProduct.reduce,
  //   ~decide=AddProduct.decide,
  //   ~initialModel=AddProduct.initialModel)
  // 1. Load relevant events from local log (filtered by DCB tag: productId="prod-42")
  // 2. Build decision model via AddProduct.reduce()
  // 3. Call AddProduct.decide(model, AddProduct(...))
  // 4. If Ok: append ProductAdded to local log, project via ProductsView.project, trigger sync
  // 5. If Error(ProductAlreadyExists): return error to caller
}
```

### 3.5 Lifecycle

**Startup:**
1. Open SQLite WASM database (OPFS or IndexedDB)
2. If first launch: create tables, pull events from server via `pullEvents(cursor: 0)`, insert as confirmed, project all
3. If returning: get last confirmed cursor, pull missed events, rebase any pending local events
4. Open subscription for live events
5. Push any pending local events
6. Render UI from projected state tables

**User action (same path online and offline — example: placing an order):**
1. User clicks "Place Order" for customer "cust-1" with products ["prod-42"]
2. `CommandHandler.dispatch(PlaceOrder({orderId: "ord-7", customerId: "cust-1", productIds: ["prod-42"]}))`
   - Load events from local log filtered by DCB tag `orderId="ord-7"`
   - Build decision model via `PlaceOrder.reduce` -> `{exists: false}`
   - Call `PlaceOrder.decide({exists: false}, PlaceOrder(...))` -> `Ok([OrderPlaced({orderId: "ord-7", customerId: "cust-1", productIds: ["prod-42"]})])`
   - Append `OrderPlaced` to local log (status: pending)
   - Project: `OrdersView.project(None, OrderPlaced(...))` -> `[Set("ord-7", {orderId: "ord-7", customerId: "cust-1", productIds: ["prod-42"], status: "placed"})]`
3. React re-renders with new order (instant, <1ms)
4. `SyncEngine.push()` sends pending event to server (async, background)
   - If online: server validates via same `PlaceOrder.decide`, confirms
   - If offline: stays pending, will push on reconnect

**Receiving server events:**
1. Subscription delivers new event batch
2. For each event: if confirmation of own pending event, mark confirmed; otherwise insert as new
3. Re-project state tables
4. If conflicts with pending events: rebase (re-validate pending events against updated decision model)

**Reconnection after offline period:**
1. Pull missed events from last confirmed cursor
2. Rebase pending events (re-validate via `decide()`, drop invalid ones)
3. Push remaining pending events
4. Re-project all state

### 3.6 Rebase Algorithm

The rebase algorithm re-validates pending events against the current server state, similar to how git rebases commits onto a new base:

1. Collect all confirmed events (including newly pulled server events)
2. For each pending event in order:
   a. Rebuild the decision model from confirmed events + previously validated pending events
   b. Re-run `decide(model, originalCommand)` for the pending event
   c. If valid: keep the event as pending
   d. If invalid: mark as rejected, notify the UI
3. Re-project all state from the merged event stream

**Example: Conflict during offline period**

1. User A (this client, offline) adds product "prod-42" -> pending `ProductAdded({productId: "prod-42", ...})`
2. User B (another client, online) also adds product "prod-42" -> server confirms `ProductAdded({productId: "prod-42", ...})`
3. User A reconnects, pulls server events including User B's `ProductAdded`
4. Rebase: re-run `AddProduct.decide({exists: true}, AddProduct({productId: "prod-42", ...}))` -> `Error(ProductAlreadyExists)`
5. User A's pending event is rejected. UI notifies: "Product 'prod-42' was already added by another user."
6. Re-project: state now shows User B's version of the product

This is ~200 lines of careful code and the most complex piece of the offline-first strategy.

### 3.7 Challenges

**Reactive queries**: LiveStore's reactive SQLite (re-render components when data changes) is hard to replicate. Options: (1) re-query on every event (simple but inefficient), (2) event-driven invalidation (track which queries depend on which event types), (3) SQLite update hooks via `sqlite3_update_hook`. Start with option 2.

**Multi-tab coordination**: Multiple tabs share the SQLite database. Options: SharedWorker (one sync connection), BroadcastChannel (leader election), or ignore it (each tab syncs independently, idempotent projections handle duplicates). Start simple.

**Event log growth**: Mitigate with compaction (periodic snapshots of confirmed state), retention windows, and lazy loading.

**Safari OPFS limitations**: Safari limits OPFS file handles to ~250, sufficient for SQLite (~5 handles). Fall back to IndexedDB on unsupported browsers.

## 4. Optimistic UI

Optimistic UI is relevant for both strategies but serves different purposes:

### 4.1 In Online-First

Optimistic UI is the primary way to achieve low-latency updates. Without it, every user action requires a server round-trip before the UI updates. With it:

1. Client predicts the event that the command will produce
2. Applies the projection locally with the predicted event
3. Sends the command to the server
4. On confirmation: reconcile (usually a no-op if prediction was correct)
5. On rejection: roll back to pre-optimistic state

The prediction step reuses the `decide` and `reduce` functions from the backend:
```rescript
// Predict the events a command will produce — example with ChangeProductPrice
let predictEvents = (~decide, ~reduce, ~initialModel, ~events, ~command) => {
  let model = events->Array.reduce(initialModel, reduce)
  decide(model, command)
}

// Using actual DCB online shop functions:
let prediction = predictEvents(
  ~decide=ChangeProductPrice.decide,
  ~reduce=ChangeProductPrice.reduce,
  ~initialModel=ChangeProductPrice.initialModel, // {exists: false, currentPrice: 0.0}
  ~events=[ProductAdded({productId: "prod-42", name: "Widget", description: "...", price: 9.99})],
  ~command=ChangeProductPrice({productId: "prod-42", price: 14.99})
)
// -> Ok([ProductPriceChanged({productId: "prod-42", price: 14.99})])
```

If the client has the current decision model (built from the event stream), its predictions will match the server's output. The prediction can only diverge if the server state has changed between the client's last received event and the server processing the command — for example, if another user deleted the product while this user was changing its price.

### 4.2 In Offline-First

Optimistic UI is **built-in** to the offline-first strategy. Every user action is validated locally via `decide()`, committed to the local event log, and projected immediately. There is no separate "optimistic" mode — the local-first write IS the optimistic update, and the sync engine handles reconciliation.

### 4.3 Complexity Comparison

| Aspect | Online-First + Optimistic UI | Offline-First (inherently optimistic) |
|--------|------------------------------|--------------------------------------|
| Single pending update | Simple rollback | Built-in |
| Multiple pending updates | Rollback-and-replay needed | Built-in (rebase) |
| Offline + optimistic | Complex hybrid | Same code path |
| Prediction accuracy | High (if event stream is current) | Always accurate (local decide) |
| Rollback complexity | Grows with pending count | Handled by rebase algorithm |

For online-first apps that need aggressive optimistic UI with multiple in-flight mutations, the complexity approaches that of offline-first. At that point, offline-first may be the simpler choice.

## 5. Comparison: Online-First vs Offline-First

| Aspect | Online-First | Offline-First |
|--------|-------------|---------------|
| Source of truth | Server (QueryDb) | Client (local event log) |
| Write path | Client -> server -> event -> local | Client -> local -> server (async) |
| Read path | Server state (initial) + subscription/poll/refresh | Local SQLite (always) |
| Local storage | In-memory only (no persistence needed) | SQLite WASM (OPFS/IndexedDB) |
| UI latency (no optimistic) | Network round-trip (~50-200ms) | <1ms (local) |
| UI latency (with optimistic) | <1ms + reconciliation | <1ms (built-in) |
| Offline writes | Disabled or queued (degraded) | Same code path as online |
| Offline reads | Last-known state (stale, read-only) | Full read/write capability |
| Reconnection | Full state refresh from server | Incremental pull + rebase |
| Conflict resolution | Server always wins (simple) | Rebase pending events (complex) |
| Real-time updates | Optional (configurable: `Live`, `Polling`, `Off`) | Optional (configurable: `Live`, `Polling`, `Off`) |
| First paint | After server query (~200ms) | After SQLite opens (~50ms on return visit) |
| Browser requirements | None special | OPFS for best performance |
| Bundle size impact | Minimal | +SQLite WASM (~300KB gzipped) |
| Implementation complexity | Low-moderate | Moderate-high |
| Code size (new) | ~400 lines | ~800 lines + ~100 lines SQLite bindings |

### 5.1 When to Choose Online-First

- **Admin panels and dashboards**: Read-heavy, always-connected environments where offline capability isn't needed
- **Multi-user collaborative UIs**: Where seeing real-time state from all users is more important than offline writes
- **Simple CRUD applications**: Where the overhead of local event storage isn't justified
- **Progressive enhancement**: Start with online-first, add offline-first later for specific features

### 5.2 When to Choose Offline-First

- **Mobile-first applications**: Unreliable network connectivity is the norm
- **Field applications**: Users work in areas with intermittent or no connectivity
- **High-interaction UIs**: Where sub-millisecond response times materially improve UX
- **Single-user workflows**: Where conflict resolution is rare and the local event log is a natural fit
- **Data entry applications**: Where losing in-progress work due to network issues is unacceptable

## 6. Unified Client Library Design

### 6.1 Approach: Single Library, Strategy as Configuration

Rather than two separate libraries, provide a single `reventless-client` package where the sync strategy is a configuration choice. Both strategies share:

- Event types, command types, and state types with sury schemas (from shared spec packages)
- Projection functions and decision functions (from shared spec packages)
- Transport layer (HTTP POST for commands, GraphQL for queries, optional WebSocket for events)
- React hooks API (same `useQuery`, `useDispatch` interface)
- Connection monitoring

The strategy determines the internal implementation:

```rescript
module ReventlessClient = {
  type strategy =
    | OnlineFirst({optimistic: bool})
    | OfflineFirst

  type realtime =
    | Off                                  // No WebSocket — poll or manual refresh only
    | Polling({intervalMs: int})           // Periodic HTTP query for new events
    | Live                                 // WebSocket subscription for instant updates

  type config = {
    strategy: strategy,
    realtime: realtime,                    // Whether to receive server events in real-time
    graphqlEndpoint: string,
    scope: string,
    projections: array<projectionConfig>,
  }

  let make: config => promise<client>
}

// Example: Online shop admin panel (online-first, optimistic, real-time updates)
let adminClient = await ReventlessClient.make({
  strategy: OnlineFirst({optimistic: true}),
  realtime: Live,
  graphqlEndpoint: "https://api.example.com/graphql",
  scope: "catalog",
  projections: [
    {name: "products", project: ProductsView.project},
    {name: "categories", project: CategoriesView.project},
    {name: "productDemand", project: ProductDemandView.project},
  ],
})

// Example: Product catalog browser (online-first, no real-time — low cost)
let catalogBrowser = await ReventlessClient.make({
  strategy: OnlineFirst({optimistic: false}),
  realtime: Off,
  graphqlEndpoint: "https://api.example.com/graphql",
  scope: "catalog",
  projections: [
    {name: "products", project: ProductsView.project},
    {name: "categories", project: CategoriesView.project},
  ],
})

// Example: Order dashboard (online-first, polling every 10 seconds)
let orderDashboard = await ReventlessClient.make({
  strategy: OnlineFirst({optimistic: false}),
  realtime: Polling({intervalMs: 10_000}),
  graphqlEndpoint: "https://api.example.com/graphql",
  scope: "ordering",
  projections: [
    {name: "orders", project: OrdersView.project},
    {name: "customers", project: CustomersView.project},
  ],
})

// Example: Field sales app (offline-first, real-time sync when online)
let fieldClient = await ReventlessClient.make({
  strategy: OfflineFirst,
  realtime: Live,
  graphqlEndpoint: "https://api.example.com/graphql",
  scope: "ordering",
  projections: [
    {name: "orders", project: OrdersView.project},
    {name: "customers", project: CustomersView.project},
    {name: "availableProducts", project: AvailableProductsView.project},
  ],
})
```

### 6.2 Shared React Hooks API

Both strategies expose the same hooks, so switching strategies doesn't require UI code changes:

```rescript
module Hooks = {
  // Query projected state — works identically for both strategies and realtime modes
  let useQuery: (client, string, ~params: array<JSON.t>=?) => queryResult<'a>

  // Dispatch a command — online-first sends to server; offline-first writes locally then syncs
  let useDispatch: client => (command => promise<Result.t<unit, error>>)

  // Manually refresh state from server — useful when realtime is Off
  // Online-first: re-queries current state from QueryDb
  // Offline-first: pulls missed events from server, re-projects
  let useRefresh: client => (unit => promise<unit>)

  // Connection and sync status
  let useSyncStatus: client => syncStatus
  // OnlineFirst + Live: Online | Offline
  // OnlineFirst + Off/Polling: Online | Offline | Stale(lastUpdateTime)
  // OfflineFirst + Live: Online | Offline | Syncing | PendingEvents(int)
  // OfflineFirst + Off/Polling: Offline | PendingEvents(int) | Stale(lastUpdateTime)
}
```

**Example usage in a React component (identical for both strategies):**

```rescript
@react.component
let make = () => {
  let products = Hooks.useQuery(client, "products")
  let dispatch = Hooks.useDispatch(client)
  let status = Hooks.useSyncStatus(client)

  let handleAddProduct = async () => {
    let result = await dispatch(
      AddProduct({productId: "prod-42", name: "Widget", description: "A fine widget", price: 9.99})
    )
    switch result {
    | Ok() => () // Product added (or will be added when synced)
    | Error(e) => showError(e)
    }
  }

  <div>
    {switch status {
     | Offline => <div className="banner"> {"Offline - changes will sync when reconnected"} </div>
     | _ => React.null
    }}
    <ProductList products />
    <button onClick={_ => handleAddProduct()->ignore}> {"Add Product"} </button>
  </div>
}
```

The `useQuery` hook abstracts over the state source:
- **Online-first**: Reads from the in-memory state store, re-renders on subscription events
- **Offline-first**: Reads from SQLite projected state tables, re-renders on local event application

The `useDispatch` hook abstracts over the command path:
- **Online-first**: Encodes `Message.commandJson` and sends via HTTP POST, optionally applies optimistic update via `AddProduct.decide` prediction
- **Offline-first**: Validates via `AddProduct.decide()`, appends `ProductAdded` to local log, projects via `ProductsView.project`, triggers sync (pushes `commandJson` via HTTP POST in background)

### 6.3 Internal Architecture

```
reventless-client/
  src/
    ReventlessClient.res           <- Public API, strategy selection
    ReventlessClient_Hooks.res     <- React hooks (shared interface)
    ReventlessClient_Transport.res <- Transport layer (commands via HTTP POST, events via GraphQL subscription, queries via GraphQL)
    ReventlessClient_Projection.res <- Action executor (shared)

    online_first/
      OnlineFirst_StateStore.res   <- In-memory state map
      OnlineFirst_Subscription.res <- Event subscription handler
      OnlineFirst_Optimistic.res   <- Optimistic UI tracker
      OnlineFirst_Client.res       <- Strategy implementation

    offline_first/
      OfflineFirst_EventLog.res    <- SQLite event log
      OfflineFirst_Projector.res   <- Event -> SQLite projector
      OfflineFirst_SyncEngine.res  <- Push/pull/rebase
      OfflineFirst_CommandHandler.res <- Local decide + append
      OfflineFirst_Client.res      <- Strategy implementation

    storage/
      SqliteWasm.res               <- SQLite WASM bindings
      SqliteStore.res              <- SQLite-backed client store
      MemoryStore.res              <- In-memory client store
```

### 6.4 Strategy Interface

Both strategies implement a common interface:

```rescript
module type ClientStrategy = {
  type t
  type config

  let init: config => promise<t>
  let getState: (t, string) => option<JSON.t>
  let query: (t, ~table: string, ~filter: filter=?) => array<JSON.t>
  let dispatch: (t, command) => promise<Result.t<unit, error>>
  let subscribe: (t, ~onChange: unit => unit) => unsubscribe
  let getSyncStatus: t => syncStatus
  let destroy: t => promise<unit>
}
```

The React hooks call into this interface, not into strategy-specific code. This makes the hooks genuinely strategy-agnostic.

### 6.5 Alternative: Separate Packages

Instead of one package with a strategy flag, provide two packages with a shared dependency:

```
reventless/
  reventless-client/          <- Shared: types, transport, projection executor, hooks interface
  reventless-client-online/   <- OnlineFirst implementation (in-memory state store)
  reventless-client-offline/  <- OfflineFirst implementation (SQLite WASM + sync engine)
```

The DCB online shop example would then look like:

```
examples/online-shop-dcb/
  catalog-spec/               <- Shared: event types, command types, state types, projections, decisions
  ordering-spec/              <- Shared: event types, command types, state types, projections, decisions
  catalog/                    <- Server plugin wiring
  ordering/                   <- Server plugin wiring
  online-shop-dcb/            <- Server platform assembly
  online-shop-admin/          <- Client: admin panel (depends on reventless-client-online + catalog-spec)
  online-shop-field/          <- Client: field sales app (depends on reventless-client-offline + ordering-spec)
```

**Advantage**: Tree-shaking. The admin panel doesn't bundle SQLite WASM (~300KB).
**Disadvantage**: More packages to maintain. Harder to switch strategies.

**Recommendation**: Start with a single package. If bundle size becomes an issue, split later. The SQLite WASM binary can be lazy-loaded only when `OfflineFirst` strategy is selected.

## 7. Command Transport: GraphQL Mutations vs Direct Commands

### 7.1 The Two Approaches

The previous sections assume the client sends commands to the backend via **GraphQL mutations** — the standard Reventless API. But there is an alternative: the client generates the same `Message.commandJson` envelopes used internally on the backend and sends them directly, bypassing the GraphQL mutation layer entirely.

**Approach A: GraphQL Mutations (as described in sections 2–6)**
```
Client UI -> GraphQL mutation -> AppSync -> Lambda -> CommandTopic -> SQS FIFO -> Aggregate
```

The client calls a typed GraphQL mutation (e.g., `Catalog_AddProduct(productId: "prod-42", name: "Widget", ...)`). AppSync resolves this to a Lambda that encodes the command and publishes it to the CommandTopic's SQS FIFO queue.

**Approach B: Direct Command Dispatch**
```
Client UI -> encode Message.commandJson -> transport (WebSocket / HTTP) -> CommandTopic -> SQS FIFO -> Aggregate
```

The client imports the same command types and sury schemas from the shared spec package, encodes the command into a `Message.commandJson` envelope (with `id`, `meta`, and `commandJson` fields), and sends it directly to the backend over a transport channel. The backend receives the pre-encoded command and routes it to the appropriate CommandTopic handler — the same handler that the GraphQL mutation Lambda would invoke.

### 7.2 What the Client Reuses

With direct command dispatch, the client reuses not just the pure decision/projection functions, but also the command encoding:

```rescript
// Client-side command dispatch using shared types from catalog-spec
let command: Message.command'<string, AddProduct.command> = {
  id: "prod-42",
  meta: {
    service: "online-shop-client",
    time: Date.now()->Date.toISOString,
    ip: None,
    user: Some(currentUser),
    msgId: Uuid.v4(),
    correlationId: Some(sessionCorrelationId),
  },
  command: AddProduct({productId: "prod-42", name: "Widget", description: "A fine widget", price: 9.99}),
}

// Encode using the same sury schema as the backend
let commandJson = Message.encode(command, AddProduct.commandSchema)

// Send via transport (WebSocket, HTTP POST, etc.)
transport->send(commandJson)
```

This is the exact same `Message.commandJson` format that `CommandTopicChannel_SQS` publishes to SQS FIFO on the backend. The command arrives at the aggregate handler in the same shape, regardless of whether it came from a GraphQL mutation resolver or directly from the client.

### 7.3 Is GraphQL Still Needed?

With direct command dispatch, the role of GraphQL changes:

| Concern | GraphQL Mutations | Direct Commands | Still needs GraphQL? |
|---------|------------------|----------------|---------------------|
| **Sending commands** | GraphQL mutation fields | Direct `Message.commandJson` | **No** — replaced by direct transport |
| **Reading state** (initial load) | GraphQL queries on QueryDb | GraphQL queries on QueryDb | **Yes** — queries remain valuable |
| **Receiving events** (real-time) | GraphQL subscriptions | WebSocket event stream | **Maybe** — depends on transport choice |
| **Schema documentation** | Self-documenting via SDL | Requires separate API docs | GraphQL has advantage |
| **Third-party API consumers** | Standard GraphQL API | Custom protocol | GraphQL has advantage |

**Conclusion**: GraphQL remains valuable for **queries** (reading projected state from QueryDb) and as a **public API** for third-party consumers. But for the Reventless client library specifically — which shares the same command types via the spec package — GraphQL mutations add a translation layer that direct command dispatch eliminates.

A hybrid approach works well: keep GraphQL for queries and for external consumers, use direct command dispatch for the Reventless client.

### 7.4 Transport Options for Direct Commands

#### Option A: AppSync WebSocket (Events API)

AppSync already provides a WebSocket endpoint (`wss://<api-id>.appsync-realtime-api.<region>.amazonaws.com/realtime`) for GraphQL subscriptions. The planned subscription infrastructure (see `docs/plans/Backlog/graphql-subscriptions-realtime.md`) uses the AppSync Events HTTP API to push events to subscribed clients.

This same WebSocket can carry commands in the upstream direction (client -> server) if the client sends them as GraphQL mutations over the WebSocket transport. However, AppSync WebSocket is designed primarily for subscriptions (server -> client), not for arbitrary client -> server messages. Using it for commands means encoding them as mutations, which circles back to the GraphQL mutation approach.

**Verdict**: Not ideal for direct commands. Better used for its intended purpose: event subscriptions.

#### Option B: API Gateway WebSocket API

AWS API Gateway supports WebSocket APIs with bidirectional communication. This is architecturally the best fit for direct command dispatch:

```
Client <--WebSocket--> API Gateway WebSocket API <--> Lambda (route handler)
                                                         |
                                                         v
                                                    CommandTopic (SQS FIFO)
                                                         |
                                                         v
                                                    Aggregate Handler
                                                         |
                                                         v
                                                    EventTopic (SNS)
                                                         |
                                                         v
                                                    Lambda -> push event back over WebSocket
```

**How it works:**
- Client opens a persistent WebSocket connection
- Client sends `Message.commandJson` as JSON frames on the WebSocket
- API Gateway routes the message to a Lambda handler based on route key (e.g., `$default` or a custom action)
- Lambda publishes the command to the CommandTopic SQS FIFO queue
- Events flow back to the client on the same WebSocket connection (pushed by a separate Lambda triggered by EventTopic SNS)

**AWS resources needed:**
- API Gateway WebSocket API (one per platform)
- Lambda `$connect` handler (auth, connection tracking)
- Lambda `$disconnect` handler (cleanup)
- Lambda `$default` or custom route handler (command dispatch)
- Lambda event pusher (EventTopic SNS -> push to connected clients)
- DynamoDB table for connection tracking (mapping connectionId -> user/scope)

**Advantages:**
- True bidirectional communication on a single connection
- Commands and events share the same connection — no separate subscription setup
- Lower latency than HTTP round-trips for commands
- Connection state enables server-initiated pushes (events) without separate subscription infrastructure
- Natural fit for both online-first (commands + events on one channel) and offline-first (sync push/pull on one channel)

**Disadvantages:**
- Additional infrastructure (API Gateway WebSocket + connection tracking DynamoDB)
- Requires connection management (reconnection, heartbeat, connection ID tracking)
- Cannot reuse existing AppSync infrastructure for this channel
- Cold start latency on Lambda handlers (mitigated by provisioned concurrency)

#### Option C: HTTP POST (API Gateway HTTP API or Lambda Function URL)

The simplest option: the client sends `Message.commandJson` as HTTP POST requests.

```
Client --HTTP POST--> API Gateway HTTP API / Lambda Function URL --> Lambda --> CommandTopic
```

**How it works:**
- Client sends each command as an HTTP POST with the `Message.commandJson` as the request body
- Lambda receives the request, validates the command envelope, and publishes to CommandTopic
- Response: synchronous acknowledgement (accepted/rejected) or async (202 Accepted, result via subscription)

**AWS resources needed (Lambda Function URL — simpler):**
- Lambda Function URL (one per command handler, or one shared handler with path-based routing)
- No additional API Gateway infrastructure

**AWS resources needed (API Gateway HTTP API — feature-rich):**
- API Gateway HTTP API with routes
- Lambda handlers per route or shared handler

**Advantages:**
- Simplest to implement — no connection state, no WebSocket management
- Reuses the existing webhook infrastructure pattern (planned in `docs/plans/Backlog/webhook-infrastructure.md`)
- Works through corporate proxies and firewalls that may block WebSocket
- Easy to test with curl/Postman
- Can return synchronous command acceptance/rejection in the HTTP response

**Disadvantages:**
- No server-initiated push — events still need a separate channel (AppSync subscription or WebSocket)
- Higher latency per command (HTTP connection overhead vs persistent WebSocket)
- No multiplexing — each command is a separate HTTP request

#### Option D: IoT Core MQTT

AWS IoT Core provides MQTT pub/sub with WebSocket transport. Clients connect via WebSocket and publish/subscribe to MQTT topics.

**How it works:**
- Client connects to IoT Core via WebSocket (MQTT over WSS)
- Client publishes commands to topic: `reventless/commands/{pluginName}/{sliceName}`
- IoT Core rule routes to Lambda -> CommandTopic
- Events published to topic: `reventless/events/{scope}` -> client receives

**Advantages:**
- True pub/sub with topic-based routing
- Built-in connection management, reconnection, QoS levels
- Scales to millions of concurrent connections
- Per-topic authorization via IoT policies

**Disadvantages:**
- Adds IoT Core as a new AWS service dependency
- MQTT semantics (QoS 0/1, retained messages) don't map naturally to command/event patterns
- IoT Core pricing is per-message, which can be expensive at high throughput
- More complex auth setup (IoT certificates or Cognito identity pool)
- Overkill for most web applications

### 7.5 Recommended Transport: HTTP POST for Commands + AppSync WebSocket for Events

The best combination for most Reventless clients:

| Direction | Transport | Why |
|-----------|-----------|-----|
| **Commands (client -> server)** | HTTP POST (Lambda Function URL or API Gateway HTTP API) | Simple, synchronous ack, no connection state, works everywhere |
| **Events (server -> client)** | AppSync WebSocket (GraphQL subscription) | Already planned, reuses existing infrastructure |
| **Initial state (client -> server)** | GraphQL query (AppSync) | Already implemented, schema-documented |

This hybrid avoids the complexity of a bidirectional WebSocket while giving each direction the best transport for its needs:

- Commands are inherently request/response (send command, get ack/rejection). HTTP POST is the natural fit.
- Events are inherently push (server decides when to send). WebSocket/subscription is the natural fit.
- Initial state is a one-time read. GraphQL query is the natural fit.

**For applications that need minimal latency and high command throughput**, upgrade to API Gateway WebSocket (Option B) for a single bidirectional channel. This is the "premium" transport that eliminates HTTP overhead and unifies commands and events on one connection.

### 7.6 Command Transport Architecture

```
+----------------------------------------------------------+
|  Browser (ReScript + React)                               |
|                                                           |
|  User Action                                              |
|       |                                                   |
|       v                                                   |
|  Encode: Message.commandJson                              |
|  (using shared sury schema from catalog-spec)             |
|       |                                                   |
|       +----> HTTP POST (command)                          |
|       |      POST /commands/catalog/AddProduct            |
|       |      Body: {id, meta, commandJson}                |
|       |                                                   |
|       +<--- AppSync WebSocket (events)                    |
|              subscription: newEvents(scope: "catalog")    |
|              -> ProductAdded({productId, name, ...})      |
|       |                                                   |
|       v                                                   |
|  Apply: ProductsView.project(state, ProductAdded(...))    |
|       |                                                   |
|       v                                                   |
|  React re-renders                                         |
+----------------------------------------------------------+
                    |           ^
         HTTP POST |           | WebSocket
                    v           |
+----------------------------------------------------------+
|  Reventless Backend (AWS)                                 |
|                                                           |
|  Lambda Function URL / API Gateway HTTP API               |
|    receive commandJson                                    |
|    validate envelope                                      |
|    publish to CommandTopic (SQS FIFO)                     |
|       |                                                   |
|       v                                                   |
|  Aggregate Handler (Lambda)                               |
|    AddProduct.decide(model, command)                      |
|    append ProductAdded to DcbEventLog                     |
|       |                                                   |
|       v                                                   |
|  EventTopic (SNS) -> Lambda -> AppSync Events API         |
|                                  -> WebSocket push        |
+----------------------------------------------------------+
```

### 7.7 Impact on Online-First and Offline-First Strategies

Direct command dispatch affects both strategies, but differently:

**Online-First:**
- Commands are sent as HTTP POST with `Message.commandJson` body instead of GraphQL mutations
- The HTTP response can return synchronous acceptance/rejection — the client knows immediately whether the command was valid
- Events still arrive via AppSync subscription, triggering `ProductsView.project` etc.
- Optimistic UI works the same: predict event via `AddProduct.decide`, apply locally, send command, reconcile on event or HTTP rejection

**Offline-First:**
- The sync engine's `push()` sends batches of pending `Message.commandJson` via HTTP POST instead of a GraphQL `pushEvents` mutation
- The sync engine's `pull()` and `subscribe()` still use GraphQL queries/subscriptions for event retrieval
- Rebase works identically — it's purely a client-side operation on the local event log

**Key difference from GraphQL mutations**: With direct commands, the client can include richer metadata in `Message.meta` (correlation IDs, client session ID, client timestamp) that flows through the entire command pipeline without needing to map it through GraphQL input types.

### 7.8 Comparison: GraphQL Mutations vs Direct Commands

| Aspect | GraphQL Mutations | Direct Commands (HTTP POST) |
|--------|------------------|----------------------------|
| Command encoding | GraphQL input types -> resolver encodes to `commandJson` | Client encodes `commandJson` directly using shared sury schema |
| Type safety | GraphQL SDL validates at API level | sury schema validates at compile time (ReScript) |
| Schema documentation | Self-documenting via GraphQL introspection | Requires separate API documentation |
| Third-party consumers | Standard GraphQL — any client can use it | Requires knowledge of `Message.commandJson` format |
| Reventless client | Extra translation layer (command -> GraphQL input -> command) | Direct: command -> `commandJson` -> transport |
| Command metadata | Limited to what GraphQL input types expose | Full `Message.meta` control (correlationId, user, custom fields) |
| Error reporting | GraphQL error format | Custom error format (can match backend's `decide` error types) |
| Backend changes | None (uses existing AppSync mutations) | New Lambda handler for HTTP command ingestion |
| Batch commands | Requires custom batch mutation field | Natural: send array of `commandJson` in one POST |
| Authentication | AppSync auth (Cognito, API key, IAM) | Lambda Function URL auth (IAM) or API Gateway auth (Cognito, API key) |

### 7.9 Recommendation

**For the Reventless client library**: Use **direct command dispatch via HTTP POST** as the primary command transport. This eliminates the unnecessary GraphQL translation layer and gives the client full control over command encoding using the same sury schemas as the backend.

**Keep GraphQL for**:
- Initial state queries (reading from QueryDb)
- Event subscriptions (AppSync WebSocket)
- Third-party API consumers who don't share the ReScript spec packages

**Implementation priority**: HTTP POST via Lambda Function URL is the simplest starting point (no API Gateway needed, uses the same pattern as the planned webhook infrastructure). Upgrade to API Gateway WebSocket for applications that need bidirectional low-latency communication.

The transport choice is orthogonal to the sync strategy (online-first vs offline-first) — both strategies benefit from direct command dispatch. The `useDispatch` hook internally encodes the command and sends it via HTTP POST instead of a GraphQL mutation, but the React component code is identical.

### 7.10 Consequences for the In-Memory Backend

The in-memory backend (`reventless-local`) is used for local development and testing. It currently accepts commands **only** via GraphQL mutations (graphql-yoga) or MCP tools, and delivers events **only** internally (bus fan-out to read model handlers — no client-facing event push). Switching to direct command dispatch and event subscriptions has significant implications for this implementation.

#### Current In-Memory Architecture

```
Client (browser or test)
    |
    v
graphql-yoga (HTTP, port 4000)
    |
    +-- Mutation resolver -> CommandGeneratorResolvers_GraphQL
    |       |
    |       v
    |   CommandTopicChannel_InMemory.dispatchCommand(channelName, {id, meta, command})
    |       |
    |       v
    |   InMemory_Bus.dispatchCommand -> registered aggregate handler
    |       |
    |       v
    |   Aggregate behavior -> EventLog.append -> EventTopic.publishJson
    |       |
    |       v
    |   InMemory_Bus.publishEvent -> PubSub fan-out -> ReadModel handlers -> QueryDb
    |
    +-- Query resolver -> Bus.getQueryDb(name) -> return state
    |
    +-- Subscription: NOT IMPLEMENTED (yoga supports it, but Reventless doesn't wire it)
```

The in-memory bus (`InMemory_Bus`) already has the low-level primitive needed for direct command dispatch: `Bus.dispatchCommand(channelName, json)` accepts a `Message.commandJson` and routes it to the registered handler. The GraphQL mutation resolver is just a thin wrapper that encodes the command and calls this function. So the bus itself is transport-agnostic — it doesn't care whether the command came from a GraphQL mutation, an HTTP POST handler, or a test function.

#### What Needs to Change

**1. Command Ingestion: Add HTTP POST endpoint alongside GraphQL**

The in-memory graphql-yoga server needs a companion HTTP endpoint that accepts `Message.commandJson` directly:

```rescript
// New: CommandHttpHandler_InMemory.res
// Registers an HTTP POST route on the graphql-yoga server (yoga supports custom routes)

let register = (server, bus) => {
  // POST /commands/:pluginName/:sliceName
  server->addRoute("POST", "/commands/*", async (req) => {
    let body = await req->readJsonBody  // Message.commandJson
    let channelName = req->extractChannelName  // from URL path
    try {
      await bus->dispatchCommand(channelName, body)
      Response.json({success: true})
    } catch {
    | exn => Response.json({success: false, error: exn->message})
    }
  })
}
```

graphql-yoga (based on `@whatwg-node/server`) supports adding arbitrary HTTP routes alongside the GraphQL endpoint. The existing yoga instance at port 4000 can serve both `/graphql` (mutations/queries) and `/commands/*` (direct command dispatch) without a second server.

The channel name mapping follows the same convention as the existing `CommandTopicChannel_InMemory`: the URL path maps to the CommandTopic resource name (e.g., `/commands/catalog/AddProduct` -> `"CatalogAddProductStateChange"` channel or similar, depending on the naming convention used by `StateChangeSlice_Builder`).

**2. Event Delivery: Add client-facing event push**

This is the bigger gap. Currently, events flow only to internal read model handlers via `InMemory_Bus.publishEvent`. There is no mechanism for an external client (browser) to receive events.

Three options for the in-memory backend:

**Option A: graphql-yoga WebSocket subscriptions**

graphql-yoga natively supports GraphQL subscriptions via WebSocket (SSE or `graphql-ws` protocol). The infrastructure is already there — Reventless just doesn't wire it. Adding subscription support to the in-memory backend would:

- Mirror the AppSync subscription behavior in production
- Require implementing `GraphQL_SubscriptionResolvers_InMemory.res` that subscribes to the bus and yields events to the yoga subscription handler
- Benefit: the client uses the same GraphQL subscription code for both in-memory dev and AWS production

```rescript
// New: GraphQL_SubscriptionResolvers_InMemory.res
// Wires InMemory_Bus event subscriptions to yoga's pubsub/subscription resolvers

let register = (server, bus) => {
  let sdl = `type Subscription { newEvents(scope: String!): EventBatch! }`

  let resolver = {
    "Subscription": {
      "newEvents": {
        "subscribe": (_root, args) => {
          let scope = args["scope"]
          // Create an AsyncIterator that yields events from Bus.subscribeToEvents
          bus->subscribeToEventAsyncIterator(scope)
        },
        "resolve": (event) => event
      }
    }
  }

  server->registerSubscriptions(~sdl, ~resolver)
}
```

This is the most architecturally consistent option: the in-memory backend behaves like a local version of the production backend, and the client library's transport layer works unchanged.

**Option B: Server-Sent Events (SSE)**

Add an SSE endpoint (`GET /events?scope=catalog`) that streams events as they occur. Simpler than WebSocket, works with standard HTTP, and graphql-yoga supports SSE natively for subscriptions.

- Pro: Simpler than WebSocket, works through proxies
- Con: Unidirectional (server -> client only), which is fine since commands go via HTTP POST
- Con: Different protocol than production (AppSync WebSocket), so the client transport layer needs an SSE adapter for dev

**Option C: Polling endpoint**

Add a `GET /events?cursor=N&scope=catalog` endpoint that returns events after the given cursor. The client polls periodically.

- Pro: Simplest to implement — just a query over the bus's event history
- Con: Not real-time (polling interval latency)
- Con: Requires the bus to retain event history (currently events are fire-and-forget to PubSub)

**Recommended: Option A (graphql-yoga WebSocket subscriptions)**. This keeps the client's subscription code identical between dev and production. graphql-yoga already supports this — the work is wiring `InMemory_Bus.subscribeToEvents` into yoga's subscription resolver pattern. This also aligns with the planned `graphql-subscriptions-realtime.md` work, which would implement the same pattern for AppSync.

**3. Event History / Catch-Up Queries**

The in-memory bus currently does not retain a queryable event history — events are published to PubSub and consumed by subscribers, but there's no `pullEvents(cursor)` equivalent. For the client's initial state load and reconnection catch-up, two options:

- **Use GraphQL queries on QueryDb** (already implemented): The client queries projected state via graphql-yoga, same as production. This works for online-first (which reads state, not events).
- **Add event history to InMemory_Bus**: For offline-first, the bus needs to store events with sequence numbers and support `getEventsAfterCursor(scope, cursor)`. This is a small extension (~50 lines) to the existing bus — append each published event to an in-memory array with an incrementing sequence number.

#### Summary of In-Memory Changes

| Capability | Current Status | What's Needed | Effort |
|-----------|---------------|---------------|--------|
| Command dispatch via bus | Exists (`Bus.dispatchCommand`) | Already transport-agnostic | None |
| HTTP POST command endpoint | Not implemented | Add route to yoga server | ~50 lines |
| GraphQL mutations | Implemented | Keep for third-party/MCP clients | None |
| GraphQL queries (state) | Implemented | No change needed | None |
| Client-facing event push | Not implemented | yoga WebSocket subscriptions | ~100 lines |
| Event history / cursor queries | Not implemented | Add event array to bus | ~50 lines (offline-first only) |
| GraphQL subscription resolvers | Not implemented | Wire bus events to yoga subscriptions | ~100 lines |

**Total new code for in-memory backend: ~200-300 lines**, depending on whether offline-first event history is needed.

The key insight is that `InMemory_Bus.dispatchCommand` is already transport-agnostic — the bus doesn't know or care whether the command came from a GraphQL mutation resolver, an HTTP POST handler, or a direct function call in a test. The work is in adding the HTTP endpoint that calls it, and in exposing events to external clients (which the bus currently only delivers internally).

#### Impact on Development Workflow

With these changes, the local development experience becomes:

```
Browser (React app)
    |
    +-- HTTP POST /commands/catalog/AddProduct  -> yoga -> Bus.dispatchCommand -> aggregate
    |
    +-- GraphQL query { products { ... } }      -> yoga -> Bus.getQueryDb -> return state
    |
    +-- WebSocket subscription newEvents(...)    -> yoga -> Bus.subscribeToEvents -> push events
```

This mirrors the production architecture:
```
Browser (React app)
    |
    +-- HTTP POST /commands/...                 -> Lambda Function URL -> CommandTopic (SQS FIFO)
    |
    +-- GraphQL query { products { ... } }      -> AppSync -> Lambda -> QueryDb (DynamoDB)
    |
    +-- WebSocket subscription newEvents(...)    -> AppSync -> EventTopic (SNS) -> push events
```

The client library's transport layer needs a simple configuration switch:

```rescript
type transportConfig =
  | Local({url: string})      // graphql-yoga: HTTP POST + WS on same host
  | Aws({
      commandUrl: string,     // Lambda Function URL
      graphqlUrl: string,     // AppSync HTTPS endpoint
      realtimeUrl: string,    // AppSync WSS endpoint
    })
```

Both configurations use the same underlying operations (HTTP POST for commands, GraphQL for queries, WebSocket for events) — only the URLs and auth differ.

## 8. Real-Time Updates: Cost Analysis and Configuration

### 8.1 Why Real-Time Is Optional

Real-time updates (WebSocket subscriptions) keep the client's state synchronized with the server as events occur. But maintaining a persistent WebSocket connection for every connected client has a cost — both in AWS charges and in backend infrastructure complexity. Many applications don't need instant updates:

- A **product catalog browser** shows products that change infrequently. Refreshing on page navigation or every few minutes is sufficient.
- A **reporting dashboard** that's checked a few times per day doesn't need a persistent connection burning costs between visits.
- A **batch data entry form** where the user adds records and submits doesn't need to see other users' changes in real-time.

Only applications with collaborative or monitoring requirements — like a **live order dashboard** where operators watch incoming orders, or a **multi-user editor** — genuinely benefit from real-time updates. Making real-time configurable lets the app developer match the cost to the use case.

### 8.2 AWS Cost of Real-Time Connections

#### AppSync WebSocket (GraphQL Subscriptions)

AWS AppSync charges for real-time subscriptions based on connection time and message volume:

| Cost Component | Price (us-east-1, as of 2025) | Notes |
|---------------|-------------------------------|-------|
| **Connection minutes** | $0.08 per million connection-minutes | A single client connected 24/7 for a month = ~43,200 minutes = $0.0035/month |
| **Outbound messages** | $2.00 per million messages | Each event pushed to a subscriber counts as one message |
| **Data transfer** | $0.09/GB (first 10TB) | JSON event payloads are typically small (<1KB) |

**Example cost scenarios:**

| Scenario | Connected clients | Connection cost/month | Events/client/day | Message cost/month | Total/month |
|----------|------------------|----------------------|-------------------|--------------------|-------------|
| **Admin panel** (5 admins, business hours) | 5 x 8h/day x 22 days | $0.04 | 500 | $0.11 | **~$0.15** |
| **Order dashboard** (10 operators, 24/7) | 10 x 24/7 | $0.35 | 2,000 | $1.20 | **~$1.55** |
| **Customer-facing app** (1,000 users, 30 min/day avg) | 1,000 x 0.5h/day x 30 days | $0.72 | 50 | $3.00 | **~$3.72** |
| **Customer-facing app** (100,000 users, 30 min/day avg) | 100,000 x 0.5h/day x 30 days | $72.00 | 50 | $300.00 | **~$372** |

At small to medium scale, AppSync WebSocket costs are negligible. At large consumer scale (100K+ daily users), the costs become meaningful — especially the outbound message charges, which scale with both user count and event frequency.

#### API Gateway WebSocket (Alternative)

If using API Gateway WebSocket instead of AppSync for event delivery:

| Cost Component | Price (us-east-1) | Notes |
|---------------|-------------------|-------|
| **Connection minutes** | $0.25 per million connection-minutes | 3x more expensive than AppSync |
| **Messages (sent)** | $1.00 per million messages | Slightly cheaper than AppSync per message |
| **Messages (received)** | $1.00 per million messages | Charged both directions |

API Gateway WebSocket is more expensive per connection-minute but cheaper per message. For applications with many long-lived connections and few events, AppSync is cheaper. For applications with brief connections and high event throughput, API Gateway may be cheaper.

#### Lambda Invocation Costs (Backend Push)

Regardless of WebSocket provider, each event push requires a Lambda invocation to bridge from EventTopic (SNS) to the WebSocket API:

| Cost Component | Price | Notes |
|---------------|-------|-------|
| **Lambda invocations** | $0.20 per million | One invocation per event batch pushed |
| **Lambda duration** | $0.0000166667 per GB-second | Typically <100ms per push at 128MB |

At 100K events/day: ~$0.006/day for invocations + ~$0.002/day for duration = negligible.

#### Cost of NOT Using Real-Time

Without real-time, the client falls back to polling or manual refresh, which uses GraphQL queries:

| Cost Component | Price | Notes |
|---------------|-------|-------|
| **AppSync query** | $4.00 per million queries | Each poll is one query |
| **Lambda invocation** (resolver) | $0.20 per million | One per query |

**Polling at 10s intervals**: 1 client x 6 queries/min x 60 min x 24h = 8,640 queries/day = $0.035/day. For 100 clients: $3.50/day = **~$105/month** — more expensive than WebSocket for the same 100 clients!

**Key insight**: Frequent polling can cost MORE than a persistent WebSocket connection. Polling is only cheaper when intervals are long (minutes, not seconds) or when the client is rarely active.

### 8.3 Cost Comparison by Realtime Mode

| Mode | Monthly cost (100 clients, 8h/day) | Freshness | Complexity |
|------|-----------------------------------|-----------|------------|
| `Live` (WebSocket) | ~$0.70 | Instant (<1s) | WebSocket connection management |
| `Polling({intervalMs: 10_000})` | ~$31.50 | 10 seconds | Simple HTTP polling |
| `Polling({intervalMs: 60_000})` | ~$5.25 | 1 minute | Simple HTTP polling |
| `Polling({intervalMs: 300_000})` | ~$1.05 | 5 minutes | Simple HTTP polling |
| `Off` (manual refresh) | ~$0.04 (refresh once per session) | On demand | None |

**Recommendation**: Default to `Live` for applications where state changes frequently and users are actively watching (dashboards, collaborative tools). Use `Polling` with a long interval (1-5 minutes) for applications where eventual consistency is acceptable. Use `Off` for applications that only need state at load time or on explicit user action.

### 8.4 Client Behavior by Realtime Mode

**`Live` — WebSocket subscription:**
- Client opens a persistent WebSocket connection on startup
- Events arrive instantly and are applied via projection functions
- State is always current (within network latency)
- Connection is monitored; reconnection with catch-up on disconnect

**`Polling({intervalMs})` — Periodic refresh:**
- No WebSocket connection
- Client queries the server at the configured interval for new state or events
- Online-first: re-queries projected state from QueryDb
- Offline-first: pulls events after last cursor, applies projections
- State may be up to `intervalMs` stale between polls
- Polling pauses when the browser tab is hidden (via `document.visibilityState`) to avoid wasting resources

**`Off` — Manual refresh only:**
- No WebSocket, no polling
- Client loads state once on startup
- State is only updated when:
  - The user explicitly triggers a refresh (pull-to-refresh, refresh button)
  - The user navigates to a different view (re-queries on mount)
  - The user dispatches a command and receives the response (online-first with optimistic UI updates the local state from the command's predicted event)
- `useSyncStatus` returns `Stale(lastUpdateTime)` so the UI can show "Last updated: 5 minutes ago"

### 8.5 Interaction with Sync Strategies

| Strategy | `Live` | `Polling` | `Off` |
|----------|--------|-----------|-------|
| **Online-first** | Full real-time. Events arrive via subscription, projections applied instantly. Best UX. | Periodically re-queries state from QueryDb. Acceptable for read-heavy apps. | State loaded once. Good for static content, forms, reports. |
| **Online-first + optimistic** | Optimistic update + instant confirmation via subscription. Ideal. | Optimistic update + deferred confirmation on next poll. Slight risk of stale rollbacks. | Optimistic update + confirmation only on manual refresh or next navigation. Risky: optimistic state may diverge for extended periods. |
| **Offline-first** | Sync engine pushes/pulls continuously. Events arrive instantly for re-projection. Full peer sync. | Sync engine runs on poll intervals. Pending events pushed, server events pulled. Acceptable lag. | Sync only on explicit refresh or app startup. Pending events queue up. Must push before state diverges too far. |

**Constraint**: Online-first without optimistic UI and with `realtime: Off` means that after dispatching a command, the client has no way to see the result until the user manually refreshes. The command's HTTP response confirms acceptance, but the resulting state change isn't visible. Options:
1. **Re-query after command**: After a successful HTTP POST, immediately query the affected state from QueryDb. This is a targeted one-shot fetch, not a subscription.
2. **Return projected state in command response**: The backend Lambda can return the resulting events in the HTTP response, allowing the client to apply projections immediately. This requires a change to the command endpoint (return events alongside the ack).

Option 1 is simpler and recommended. The `useDispatch` hook can trigger a targeted refresh after each successful command, regardless of the `realtime` setting:

```rescript
// Inside useDispatch (online-first, realtime: Off)
let dispatch = async (command) => {
  let result = await transport->sendCommand(commandJson)
  switch result {
  | Ok(_) =>
    // Command accepted — immediately refresh affected state
    await client->refreshState()
    Ok()
  | Error(e) => Error(e)
  }
}
```

### 8.6 Configuration Examples by Application Type

```rescript
// 1. Live order monitoring dashboard (operators watch incoming orders)
{strategy: OnlineFirst({optimistic: false}), realtime: Live, ...}
// Cost: Low (few operators). Real-time is essential.

// 2. Admin panel for catalog management (5 admins, occasional edits)
{strategy: OnlineFirst({optimistic: true}), realtime: Polling({intervalMs: 30_000}), ...}
// Cost: Negligible. 30s polling is enough — admins rarely conflict.

// 3. Public product catalog (read-only browsing, thousands of users)
{strategy: OnlineFirst({optimistic: false}), realtime: Off, ...}
// Cost: Minimal (one query per page load). No WebSocket, no polling.

// 4. Field sales app (offline-first, sync when connected)
{strategy: OfflineFirst, realtime: Live, ...}
// Cost: Low (field staff count is small). Real-time sync avoids stale data.

// 5. Warehouse inventory app (offline-first, periodic sync)
{strategy: OfflineFirst, realtime: Polling({intervalMs: 60_000}), ...}
// Cost: Low. 1-minute sync intervals keep inventory reasonably fresh.

// 6. Monthly report generator (one-time state load)
{strategy: OnlineFirst({optimistic: false}), realtime: Off, ...}
// Cost: Near zero. Loads state once, generates report, done.
```

### 8.7 In-Memory Backend Implications

The `realtime` configuration is also relevant for local development with the in-memory backend:

- **`Live`**: Requires the graphql-yoga WebSocket subscription support described in section 7.10. During local dev, events are pushed via yoga's native WebSocket support.
- **`Polling`**: Works with the existing GraphQL query infrastructure — no WebSocket needed. The client periodically queries state via `GET /graphql`.
- **`Off`**: No additional infrastructure needed. The client queries state on demand.

For local development, `Polling` or `Off` may be preferred during early development when the WebSocket subscription infrastructure isn't yet wired. The client works correctly without it — just without real-time updates. This means the in-memory WebSocket support (section 7.10) can be deferred until `Live` mode is needed.

## 9. Comparison with LiveStore

| Aspect | LiveStore | Reventless Client (proposed) |
|--------|-----------|------------------------------|
| Event log | Local SQLite eventlog | SQLite (offline-first) or none (online-first) |
| Projections | Materializers (event -> SQL) | project() -> action -> applyAction() |
| Reactive queries | `useQuery` (reactive SQLite) | `useQuery` (strategy-agnostic) |
| Sync | Push/pull with rebasing | Push/pull with rebasing (offline-first) or subscription (online-first) |
| Real-time updates | Always on (WebSocket) | Configurable: `Live`, `Polling({intervalMs})`, or `Off` |
| Validation | Materializer rollback | decide() before event creation |
| Command transport | WebSocket (Effect RPC) | HTTP POST with `Message.commandJson` (or GraphQL mutation for third-party clients) |
| Event transport | WebSocket (Effect RPC) | AppSync WebSocket (when `Live`), HTTP polling, or none |
| Online-first mode | Not supported (always local-first) | First-class support |
| Language | TypeScript + Effect | ReScript |
| Schema | Effect Schema | sury (@schema PPX) |

The key difference: LiveStore only supports offline-first. The proposed Reventless client supports both strategies, letting the developer choose based on their application's requirements.

### 9.1 Advantages of Custom ReScript Implementation

1. **Same language end-to-end**: Server and client both in ReScript. No schema bridge needed.
2. **Direct code reuse**: `decide`, `reduce`, `project` functions used verbatim on client and server.
3. **Two strategies**: Online-first option that LiveStore doesn't offer.
4. **No Effect dependency**: Avoids binding the Effect TypeScript ecosystem.
5. **Thinner runtime**: Only need SQLite WASM bindings for offline-first; nothing extra for online-first.
6. **Full control**: Can tailor sync behavior to Reventless's specific patterns (DCB tags, sequence numbers, EventTopic integration).
7. **Direct command dispatch**: Client sends `Message.commandJson` natively — no translation layer.

### 9.2 Advantages of Using LiveStore Instead

1. **Mature sync engine**: Rebasing, conflict resolution, cursor management are battle-tested.
2. **Reactive query engine**: Sophisticated dependency tracking, incremental updates.
3. **Ecosystem**: Existing sync providers, dev tools, documentation.
4. **Maintenance**: Actively maintained by a dedicated team.

### 9.3 Recommendation

**Build a custom client library in ReScript.** The online-first strategy alone justifies it — LiveStore can't provide that. And for offline-first, reusing Reventless's code on the client gives the same functionality without the Effect Schema bridge.

## 10. Existing Library Assessment

| Library | Why It Doesn't Fit |
|---------|-------------------|
| **LiveStore** | Offline-first only. No online-first mode. Effect/TypeScript ecosystem. |
| **ElectricSQL** | Sync engine for Postgres state, not event sourcing |
| **Replicache / Zero** | Mutation-based, not event-sourced. Replicache in maintenance mode. |
| **Evolu** | CRDT-based with last-write-wins. No domain events, no invariant enforcement. |
| **PowerSync** | CRUD sync layer, not event sourcing |
| **Yjs / Automerge** | CRDTs for convergent state. Cannot maintain ordered event logs. |
| **TanStack Query** | Server-state cache. Could complement online-first but doesn't handle event projection. |

No existing library provides event-sourced client state with projection reuse from a ReScript backend. A custom implementation is required.

## 11. Implementation Roadmap

### Phase 1: Foundation (both strategies)
- Extract pure types and functions from `catalog/` and `ordering/` into `catalog-spec/` and `ordering-spec/` (event types, command types, state types, StateViewSlice projections, StateChangeSlice decide/reduce)
- Transport layer: HTTP POST for commands (Lambda Function URL), GraphQL queries for state, AppSync subscription for events
- Client store interface (shared trait)
- Backend (AWS): Lambda Function URL handler that receives `Message.commandJson` and publishes to CommandTopic
- Backend (in-memory): HTTP POST route on graphql-yoga for direct command dispatch, WebSocket subscription support wired to `InMemory_Bus`

### Phase 2: Online-First
- In-memory state store
- Subscription handler (apply events via projection)
- State query (initial load + reconnection)
- React hooks (useQuery, useDispatch, useSyncStatus)
- Connection monitoring

### Phase 3: Online-First + Optimistic UI
- Optimistic update tracker
- Prediction via local `decide()`
- Reconciliation on confirmation
- Rollback on rejection

### Phase 4: Offline-First Core
- SQLite WASM ReScript bindings (wa-sqlite + OPFS)
- EventLog module (append, query, confirm/reject)
- Projector module (apply actions to SQLite state tables)
- CommandHandler (decide + append + project)

### Phase 5: Offline-First Sync
- Pull: catch-up query via GraphQL
- Push: batch `Message.commandJson` via HTTP POST
- Subscribe: AppSync WebSocket for live events
- Rebase algorithm

### Phase 6: Production Readiness
- Event log compaction / snapshots (offline-first)
- Multi-tab coordination (offline-first)
- OPFS -> IndexedDB fallback (offline-first)
- Error handling, retry logic, connection management (both)

### Phase 7: DX Improvements
- Reactive query engine (SQLite update hooks for offline-first)
- DevTools (event log inspector, sync status)
- Code generation for React hooks from projection specs

## 12. Conclusion

A ReScript-based client library for Reventless should support two sync strategies: **online-first** for applications that treat the server as the source of truth, and **offline-first** for applications that need full local autonomy.

Both strategies reuse the same backend code (event types, command types, state types, projection functions, decision logic) and the same transport layer. Commands are sent as `Message.commandJson` via HTTP POST — using the same sury-encoded format as the backend's internal CommandTopic — eliminating the unnecessary GraphQL mutation translation layer. Events arrive via AppSync WebSocket subscription (when real-time is enabled), periodic polling, or on-demand refresh. Initial state is loaded via GraphQL queries. The difference between strategies is architectural: online-first stores state ephemerally in memory and depends on the server for durability, while offline-first maintains a local event log in SQLite and syncs as a peer.

By designing a single library with three configuration axes — **strategy** (online-first vs offline-first), **optimistic UI** (on or off), and **real-time updates** (`Live`, `Polling`, or `Off`) — app developers can precisely match the client's behavior and cost profile to their use case. A live order dashboard uses `OnlineFirst + Live`; a public catalog browser uses `OnlineFirst + Off`; a field sales app uses `OfflineFirst + Live`. The shared hooks API means changing any of these settings requires no UI code changes, only a configuration change at initialization.

The online-first strategy is simpler to implement (~400 lines of new code) and suitable for always-connected applications like the online shop's admin panel. The offline-first strategy is more complex (~900 lines) but provides genuine offline capability with sub-millisecond UI updates, suitable for a field sales app that needs to place orders without connectivity. Optimistic UI bridges the gap for online-first, giving instant feedback while maintaining the server as the source of truth.

The DCB online shop example (`examples/online-shop-dcb/`) demonstrates the concrete reuse: `ProductsView.project`, `OrdersView.project`, `AddProduct.decide`, `PlaceOrder.decide`, and all other pure StateViewSlice/StateChangeSlice functions can run unmodified on both server and client. The only new code is the thin adapter layer that wires these functions to either in-memory maps or SQLite tables.
