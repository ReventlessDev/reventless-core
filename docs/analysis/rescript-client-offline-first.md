# ReScript Client with Real-Time Updates and Offline-First Event Sourcing

## Executive Summary

This analysis explores how a ReScript-based React client could integrate with a Reventless backend using an offline-first, event-sourced architecture. The client always writes to a local event log (both online and offline), projects events locally using the same projection functions as the server, and synchronizes events with the backend via GraphQL.

The key insight is that by running in "offline mode" at all times — always writing locally first, then syncing — the client becomes genuinely offline-first rather than treating offline as a degraded fallback. This is architecturally identical to what LiveStore implements, but built natively in ReScript, reusing Reventless's existing projection functions and event types.

## 1. Architecture Overview

### 1.1 End-to-End Data Flow

```
┌─────────────────────────────────────────────────────────────┐
│  Browser (ReScript + React)                                 │
│                                                             │
│  User Action                                                │
│       │                                                     │
│       v                                                     │
│  StateChangeSlice.decide()  ← reused from backend           │
│       │                                                     │
│       v                                                     │
│  Local Event Log (SQLite WASM / OPFS)                       │
│       │                                                     │
│       v                                                     │
│  Projection.project()  ← reused from backend                │
│       │                                                     │
│       v                                                     │
│  Client State Store (in-memory / SQLite)                    │
│       │                                                     │
│       v                                                     │
│  React UI (reactive queries)                                │
│                                                             │
│  ┌──────────────────────┐                                   │
│  │ Sync Engine          │                                   │
│  │  push: mutation ────────────────────────────────────┐    │
│  │  pull: subscription ←───────────────────────────┐   │    │
│  │  catch-up: query ←─────────────────────────┐    │   │    │
│  └──────────────────────┘                      │    │   │    │
└────────────────────────────────────────────────┼────┼───┼────┘
                                                 │    │   │
┌────────────────────────────────────────────────┼────┼───┼────┐
│  Reventless Backend (AWS)                      │    │   │    │
│                                                │    │   │    │
│  GraphQL API (AppSync)                         │    │   │    │
│    query: pullEvents(cursor) ──────────────────┘    │   │    │
│    subscription: newEvents(scope) ──────────────────┘   │    │
│    mutation: pushEvents(batch) ─────────────────────────┘    │
│       │                                                      │
│       v                                                      │
│  Sync API / Event Validator                                  │
│       │                                                      │
│       v                                                      │
│  DcbEventLog (DynamoDB)                                      │
│       │                                                      │
│       v                                                      │
│  EventTopic (SNS) → ReadModels / StateViewSlices → QueryDb   │
└──────────────────────────────────────────────────────────────┘
```

### 1.2 Two Modes of Operation

**Online-first (naive approach — NOT recommended):**
1. Client queries current state from QueryDb via GraphQL
2. Client receives live events via GraphQL subscription
3. Client projects events locally to update UI
4. When offline, client falls back to local event creation + sync on reconnect

**Offline-first (recommended approach — "always local"):**
1. Client always writes events to the local event log first
2. Client always projects events locally for immediate UI updates
3. Sync engine pushes local events to backend when connected
4. Sync engine pulls server events and rebases local pending events
5. Online and offline use the same code path — no mode switching

The offline-first approach is superior because:
- **Zero latency UI updates**: No round-trip to server for state changes
- **No mode switching**: Same code path online and offline
- **Resilient**: Network failures don't degrade UX
- **Simpler mental model**: Local event log is always the source of truth for the client

## 2. Reusing Backend Code on the Client

### 2.1 What Can Be Reused

Reventless projection and validation functions are **pure ReScript functions** that compile to plain JavaScript with no server-side dependencies:

| Backend Component | Client Reuse | Dependencies |
|-------------------|-------------|--------------|
| `@schema type event` (event types + sury schemas) | Direct reuse | sury runtime only |
| `StateViewSlice.project(state, event)` | Direct reuse | Event types, state types |
| `StateChangeSlice.decide(model, command)` | Direct reuse | Event types, command types |
| `StateChangeSlice.reduce(model, event)` | Direct reuse | Event types, decision model type |
| `Projection.action` type | Direct reuse | None (algebraic type) |
| `Projection.handleAction` | **Cannot reuse** | QueryDb storage operations |
| `ReadModel_Callback.handleJsonEvents` | **Cannot reuse** | EventCollector, stream infrastructure |
| `EventCollector`, `EventTopic` | **Cannot reuse** | AWS infrastructure (SQS, SNS) |

The pure functions (project, decide, reduce) have no I/O, no async, no infrastructure coupling. They take events in and return actions/decisions out.

### 2.2 Shared Package Structure

Create a shared package containing only the portable code:

```
reventless/
  reventless-spec/          ← existing: type definitions
  reventless-core/          ← existing: server runtime
  reventless-shared/        ← NEW: isomorphic code (runs on server AND client)
    src/
      events/
        CatalogEvents.res   ← @schema type event (shared event types)
      projections/
        ProductsView.res    ← project(state, event) → actions
        CategoriesView.res
      decisions/
        AddProduct.res      ← decide(model, command) → Result
        ChangeProductName.res
      Projection.res        ← action type + pure helpers (no handleAction)
```

The shared package:
- Has no dependency on `reventless-core` or `reventless-aws`
- Depends only on `sury` (for `@schema` serialization)
- Compiles to JavaScript that runs in both Node.js and browser
- Is consumed by both the server-side builders AND the client-side app

The server-side builders import from the shared package and wire projections to infrastructure. The client imports the same projections and wires them to local storage.

### 2.3 Projection on the Client

The `project` function returns `Projection.action` values. On the server, `Projection.handleAction` executes these against DynamoDB via QueryDb. On the client, a thin adapter executes them against local state:

```rescript
// Client-side action executor (new, client-only)
let applyAction = (store: clientStore, action: Projection.action<string, 'state>) =>
  switch action {
  | Set(id, state) => store->put(id, state)
  | Update(id, f) =>
    switch store->get(id) {
    | Some(current) => store->put(id, f(current))
    | None => () // entity doesn't exist yet
    }
  | Delete(id) => store->remove(id)
  | Create(id, state) => store->put(id, state)
  | Ignore => ()
  // ... handle remaining action variants
  }
```

This is ~50 lines of code — the client-side equivalent of `Projection.handleAction`, but writing to an in-memory map or SQLite instead of DynamoDB.

## 3. Client-Side Event Log Storage

### 3.1 Browser Database Options

The client needs a durable, append-only event log in the browser. The options:

| Storage | Write Latency | Query | Persistence | Size | Browser Support |
|---------|--------------|-------|-------------|------|-----------------|
| **SQLite WASM + OPFS** | ~1ms | Full SQL | Durable | ~10% of disk | Chrome/Edge full, Firefox progressing, Safari limited |
| **SQLite WASM + IndexedDB** | ~3ms | Full SQL | Durable (evictable) | ~10% of disk | Universal |
| **IndexedDB (raw)** | ~3ms | Key-value + indexes | Durable (evictable) | ~10% of disk | Universal |
| **Dexie.js** (IDB wrapper) | ~2ms | Indexed queries | Same as IDB | Same as IDB | Universal |
| **PGlite** (Postgres WASM) | ~1ms (WAL) | Full Postgres SQL | OPFS or IDB | Same, but ~3MB WASM download | Safari broken (file handle limit) |

### 3.2 Recommendation: SQLite WASM with OPFS (primary) + IndexedDB (fallback)

**SQLite WASM** is the best fit because:

1. **SQL queries over events**: Query by sequence number, event type, entity ID, cursor ranges — all natural SQL operations needed for the sync engine
2. **Append-only performance**: ~1ms writes via OPFS, which is ideal for an event log
3. **Shared model with LiveStore**: LiveStore also uses SQLite WASM, validating the approach
4. **Projection state storage**: The projected state (equivalent of QueryDb) can live in the same SQLite database, queried reactively by React components
5. **ReScript bindings are feasible**: SQLite's API surface is small (prepare, bind, step, get) compared to binding a library like LiveStore

**Schema:**

```sql
-- Event log (append-only)
CREATE TABLE events (
  local_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  global_sequence INTEGER,          -- null until confirmed by server
  event_type TEXT NOT NULL,         -- TAG value (e.g., "ProductAdded")
  payload TEXT NOT NULL,            -- JSON payload
  client_id TEXT NOT NULL,          -- this client's ID
  status TEXT DEFAULT 'pending',    -- pending | confirmed | rejected
  created_at TEXT NOT NULL
);

CREATE INDEX idx_events_status ON events(status);
CREATE INDEX idx_events_global ON events(global_sequence);

-- Projected state (derived from events, rebuildable)
CREATE TABLE products (
  product_id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT,
  price REAL NOT NULL
);

CREATE TABLE categories (
  category_id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  archived INTEGER DEFAULT 0
);
```

### 3.3 ReScript Bindings for SQLite WASM

The binding surface is small — roughly 10-15 functions:

```rescript
// Minimal SQLite WASM bindings
module Sqlite = {
  type db
  type statement

  @module("wa-sqlite") external open_: string => promise<db> = "open"
  @send external exec: (db, string) => promise<unit> = "exec"
  @send external prepare: (db, string) => promise<statement> = "prepare"
  @send external bind: (statement, array<JSON.t>) => unit = "bind"
  @send external step: statement => promise<bool> = "step"
  @send external getAsObject: statement => JSON.t = "getAsObject"
  @send external finalize: statement => unit = "finalize"
}
```

This is a fraction of the effort compared to binding LiveStore's Effect-heavy API.

## 4. Client Architecture: Components

### 4.1 Component Overview

```
┌────────────────────────────────────────────────────────┐
│  Reventless Client Library (new ReScript package)      │
│                                                        │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐ │
│  │ EventLog     │  │ Projector    │  │ SyncEngine   │ │
│  │              │  │              │  │              │ │
│  │ append()     │  │ project()    │  │ push()       │ │
│  │ getAfter()   │  │ rebuild()    │  │ pull()       │ │
│  │ getPending() │  │ applyAction()│  │ rebase()     │ │
│  │ confirm()    │  │              │  │ subscribe()  │ │
│  │ reject()     │  │              │  │              │ │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘ │
│         │                 │                  │         │
│         v                 v                  v         │
│  ┌──────────────────────────────────────────────────┐  │
│  │ SQLite WASM (OPFS / IndexedDB)                   │  │
│  │  - events table (append-only log)                │  │
│  │  - projected state tables (derived)              │  │
│  └──────────────────────────────────────────────────┘  │
│                                                        │
│  ┌──────────────┐  ┌──────────────┐                    │
│  │ CommandHandler│  │ ReactHooks   │                    │
│  │              │  │              │                    │
│  │ dispatch()   │  │ useQuery()   │                    │
│  │ validate()   │  │ useDispatch()│                    │
│  │              │  │              │                    │
│  └──────────────┘  └──────────────┘                    │
└────────────────────────────────────────────────────────┘
```

### 4.2 EventLog

Manages the local append-only event log in SQLite:

```rescript
module EventLog = {
  let append: (db, event) => promise<localSequence>
  let getAfterCursor: (db, ~cursor: int) => promise<array<event>>
  let getPending: db => promise<array<event>>
  let confirmBatch: (db, ~localSequences: array<int>, ~globalSequences: array<int>) => promise<unit>
  let rejectBatch: (db, ~localSequences: array<int>) => promise<unit>
  let getLastConfirmedCursor: db => promise<option<int>>
}
```

### 4.3 Projector

Applies projection functions to events, writing results to the state tables:

```rescript
module Projector = {
  // Apply a single event to projected state
  let projectEvent: (db, event, ~project: (option<'state>, event) => array<action>) => promise<unit>

  // Rebuild all projected state from the event log (on startup or after rebase)
  let rebuild: (db, ~project: (option<'state>, event) => array<action>) => promise<unit>
}
```

The `project` function is imported directly from the shared package — the same function used on the server in StateViewSlice.

### 4.4 SyncEngine

Handles push/pull synchronization with the backend via GraphQL:

```rescript
module SyncEngine = {
  type status = Online | Offline | Syncing

  let push: (db, ~graphqlClient: client) => promise<pushResult>
  // Sends pending events to server via pushEvents mutation
  // On success: marks events as confirmed with global sequence numbers
  // On rejection: marks events as rejected, triggers rebase

  let pull: (db, ~graphqlClient: client, ~cursor: int) => promise<array<event>>
  // Queries pullEvents for events after cursor
  // Inserts confirmed server events into local log
  // Triggers re-projection

  let subscribe: (db, ~graphqlClient: client, ~scope: string) => subscription
  // Opens GraphQL subscription for live events
  // On each event batch: insert into local log, re-project

  let rebase: (db, ~serverEvents: array<event>, ~pendingEvents: array<event>) => promise<unit>
  // Re-applies pending events on top of new server events
  // Re-validates each pending event via decide()
  // Drops invalid events, re-projects all state
}
```

### 4.5 CommandHandler

Validates commands locally using the shared `decide` function, then commits events:

```rescript
module CommandHandler = {
  let dispatch: (
    db,
    ~command: command,
    ~reduce: (decisionModel, event) => decisionModel,
    ~decide: (decisionModel, command) => Result.t<array<event>, error>,
    ~initialModel: decisionModel,
  ) => promise<Result.t<array<event>, error>>
  // 1. Load relevant events from local log
  // 2. Build decision model via reduce()
  // 3. Call decide(model, command)
  // 4. If Ok: append events to local log, project, trigger sync
  // 5. If Error: return error to caller
}
```

This reuses the exact same `decide` and `reduce` functions from the backend StateChangeSlice specs.

### 4.6 React Hooks

```rescript
module Hooks = {
  let useQuery: (db, string, ~params: array<JSON.t>=?) => 'result
  // Reactive SQL query against projected state tables
  // Re-renders when underlying data changes

  let useDispatch: (commandHandler) => (command => promise<Result.t<unit, error>>)
  // Returns a dispatch function for sending commands

  let useSyncStatus: syncEngine => status
  // Returns current sync status (Online/Offline/Syncing)
}
```

## 5. Lifecycle: Online and Offline

### 5.1 Client Startup

```
1. Open SQLite WASM database (OPFS or IndexedDB)
2. If first launch:
   a. Create event log and state tables
   b. Query server for initial state: pullEvents(cursor: 0)
   c. Insert all events into local log (status: confirmed)
   d. Project all events to build state tables
3. If returning:
   a. Get last confirmed cursor from local log
   b. Pull missed events: pullEvents(cursor: lastConfirmed)
   c. Insert new server events, re-project
   d. Rebase any pending (unconfirmed) local events
4. Open GraphQL subscription for live events
5. Push any pending local events
6. Render UI from projected state tables
```

### 5.2 User Action (Same Path Online and Offline)

```
1. User clicks "Add Product"
2. CommandHandler.dispatch(AddProduct({productId, name, price}))
   a. Load relevant events from local log
   b. Build decision model: reduce over events
   c. decide(model, AddProduct(...)) → Ok([ProductAdded(...)])
   d. Append ProductAdded to local log (status: pending)
   e. Project: apply ProductsView.project(state, ProductAdded(...))
   f. Update state table: INSERT INTO products VALUES(...)
3. React re-renders with new product (instant, <1ms)
4. SyncEngine.push() sends pending event to server (async, background)
   - If online: server validates, confirms → mark confirmed
   - If offline: stays pending, will push on reconnect
```

### 5.3 Receiving Server Events (Online)

```
1. GraphQL subscription delivers new event batch
2. For each event:
   a. Check if this is a confirmation of our own pending event
      - If yes: mark local event as confirmed, assign global sequence
      - If no: insert as new confirmed event
   b. Re-project state tables
3. If new server events conflict with pending local events:
   a. Rebase: re-validate pending events against updated decision model
   b. Drop events that no longer validate
   c. Re-project all state from scratch
4. React re-renders from updated state tables
```

### 5.4 Reconnection After Offline Period

```
1. Connection restored
2. Pull missed events: pullEvents(cursor: lastConfirmedCursor)
3. Insert server events into local log
4. Rebase pending events:
   a. For each pending event, rebuild decision model including new server events
   b. Re-validate via decide()
   c. If still valid: keep pending
   d. If invalid: mark rejected, notify UI
5. Push remaining pending events to server
6. Re-project all state
7. Open subscription for live events
```

### 5.5 Why This Is Offline-First

The architecture is offline-first because:

1. **No mode switching**: The client always writes locally first, always projects locally, always syncs asynchronously. Whether the network is available doesn't change the code path.

2. **Local event log is the client's source of truth**: All reads come from local SQLite. All writes go to local SQLite. The server is a peer that the client syncs with, not a dependency.

3. **Instant UI updates**: Every user action takes effect in <1ms (local SQLite write + projection). No loading spinners, no optimistic-then-rollback patterns.

4. **Graceful degradation**: If the server is unreachable, everything works except sync. Pending events queue up. On reconnect, they sync automatically.

5. **Conflict resolution is built-in**: The rebase mechanism handles divergence between client and server state, just as git handles divergent branches.

## 6. Comparison with LiveStore

### 6.1 Architectural Alignment

| Aspect | LiveStore | Reventless Client (proposed) |
|--------|-----------|------------------------------|
| Event log | Local SQLite eventlog | Local SQLite events table |
| Projections | Materializers (event → SQL) | project() → action → applyAction() |
| Reactive queries | `useQuery` (reactive SQLite) | `useQuery` (reactive SQLite) |
| Sync | Push/pull with rebasing | Push/pull with rebasing |
| Validation | Materializer rollback | decide() before event creation |
| Transport | WebSocket (Effect RPC) | GraphQL (subscription + mutation) |
| Language | TypeScript + Effect | ReScript |
| Schema | Effect Schema | sury (@schema PPX) |

The two architectures are structurally identical. The differences are in implementation language and schema system, not in the fundamental model.

### 6.2 Advantages of Custom ReScript Implementation

1. **Same language end-to-end**: Server and client both in ReScript. No schema bridge needed.
2. **Direct code reuse**: `decide`, `reduce`, `project` functions used verbatim on client and server.
3. **No Effect dependency**: Avoids binding the Effect TypeScript ecosystem.
4. **Thinner runtime**: Only need SQLite WASM bindings (~15 functions), not a full framework.
5. **Full control**: Can tailor sync behavior to Reventless's specific patterns (DCB tags, sequence numbers, EventTopic integration).

### 6.3 Advantages of Using LiveStore Instead

1. **Mature sync engine**: Rebasing, conflict resolution, cursor management are complex. LiveStore has this battle-tested.
2. **Reactive query engine**: LiveStore's reactive SQLite layer is sophisticated (dependency tracking, incremental updates). Building this from scratch is significant effort.
3. **Ecosystem**: LiveStore has existing sync providers, dev tools, and documentation.
4. **Maintenance**: LiveStore is actively maintained. A custom implementation is maintained by you.

### 6.4 Recommendation

**Build a thin custom client library in ReScript** rather than using LiveStore.

The reasoning:
- The core value of LiveStore (event log + projections + sync) is exactly what Reventless already provides on the server. Reusing Reventless's code on the client gives you the same functionality without the Effect Schema dependency.
- The sync engine is the hardest part to build, but it's also the most Reventless-specific part (DCB validation, tag-based queries, global sequence numbers). A generic sync engine would need extensive customization anyway.
- The reactive query layer is the biggest engineering effort to replicate. However, a simpler approach (poll on event, re-query) is sufficient for many applications, with a full reactive layer added later if needed.

## 7. Existing Library Assessment

### 7.1 Libraries That Don't Fit

| Library | Why It Doesn't Fit |
|---------|-------------------|
| **ElectricSQL** | Sync engine for Postgres state, not event sourcing |
| **Replicache / Zero** | Mutation-based, not event-sourced. Replicache in maintenance mode. |
| **Evolu** | CRDT-based with last-write-wins. No domain events, no invariant enforcement. |
| **PowerSync** | CRUD sync layer, not event sourcing |
| **Yjs / Automerge** | CRDTs for convergent state. Cannot maintain ordered event logs. |

### 7.2 No ReScript-Native Solution Exists

There are no ReScript-specific local-first or client-side event sourcing libraries. The ReScript ecosystem is small and focused on React bindings.

### 7.3 Build from Scratch — But It's Less Than It Sounds

The "from scratch" implementation is smaller than it appears because:

1. **Projections, validation, event types**: Reused from backend (0 new code)
2. **SQLite WASM bindings**: ~100 lines of ReScript FFI
3. **EventLog module**: ~150 lines (append, query, confirm/reject)
4. **Projector module**: ~100 lines (apply actions to SQLite, rebuild)
5. **SyncEngine module**: ~300 lines (push/pull/rebase via GraphQL)
6. **CommandHandler**: ~50 lines (decide + append + project)
7. **React hooks**: ~100 lines (useQuery, useDispatch, useSyncStatus)

**Total new code: ~800 lines of ReScript**, excluding the shared projection/validation code that already exists. This is feasible for a single developer in a few weeks. The sync engine (rebase logic) is the most complex piece.

## 8. Transport: GraphQL Integration

### 8.1 Three GraphQL Operations

**Query (catch-up pull):**
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

**Mutation (push):**
```graphql
mutation PushEvents($batch: [EventInput!]!, $cursor: Int!) {
  pushEvents(batch: $batch, cursor: $cursor) {
    success
    newCursor
    rejected {
      localSequence
      error
    }
  }
}
```

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

### 8.2 Initial State: Query vs Event Replay

Two options for initializing a new client:

**Option A: Full event replay** — Pull all events from sequence 0, replay locally.
- Pro: Client has full event history, can rebuild any projection
- Con: Slow for large event logs. Client downloads entire history.

**Option B: State snapshot + live events** — Query current state from QueryDb via GraphQL, then subscribe for new events.
- Pro: Fast startup. Client gets current state immediately.
- Con: Client has no event history before the snapshot. Cannot re-project from scratch.

**Recommended: Hybrid** — Query current state for immediate display, then pull events from a recent cursor for the sync engine. The state query is the fast path for initial render; the event pull catches up the local event log for sync purposes. Use server-side snapshots/compaction for old events to bound the catch-up size.

### 8.3 AppSync Compatibility

All three operations work with AWS AppSync:
- **Query**: Standard AppSync resolver → Lambda → DcbEventLog query
- **Mutation**: AppSync resolver → Lambda → Sync API validate + append
- **Subscription**: AppSync real-time endpoint (WebSocket). Events pushed via EventTopic → Lambda → AppSync Events HTTP API → subscribed clients.

This reuses the existing AppSync deployment and the planned subscription infrastructure (see `docs/plans/Backlog/graphql-subscriptions-realtime.md`).

## 9. Challenges and Open Questions

### 9.1 Reactive Queries

LiveStore's reactive SQLite (re-render React components when underlying data changes) is the hardest piece to replicate. Options:

1. **Simple polling**: Re-query on every event. Works but inefficient for large state.
2. **Event-driven invalidation**: Track which queries depend on which event types. When an event arrives, invalidate and re-run affected queries. Moderate complexity.
3. **SQLite update hooks**: wa-sqlite supports `sqlite3_update_hook` which fires on INSERT/UPDATE/DELETE. Use this to trigger React re-renders for affected tables. Most LiveStore-like, but requires careful integration.

Start with option 2 (event-driven invalidation) and evolve to option 3 if needed.

### 9.2 Rebase Complexity

The rebase algorithm (re-validating pending events against new server state) is the most complex piece:

- Must rebuild the decision model from the merged event stream (server confirmed + local pending)
- Must re-run `decide()` for each pending event in order
- Must handle cascading invalidation (if event A is rejected, event B that depends on A may also be invalid)
- Must update projected state after rebase

This is ~200 lines of careful code. LiveStore's implementation is battle-tested; a custom implementation needs thorough testing.

### 9.3 Multi-Tab Coordination

If the user has multiple browser tabs open, they share the same SQLite database (OPFS). Options:

- **SharedWorker**: Run the sync engine in a SharedWorker, shared across tabs. Only one sync connection.
- **BroadcastChannel**: One tab is the "leader" (runs sync). Others receive updates via BroadcastChannel. Leader election on tab close.
- **Ignore it**: Each tab runs its own sync engine. Possible duplicate events, but idempotent projections handle it.

Start with "ignore it" (each tab syncs independently) and add SharedWorker coordination later.

### 9.4 Safari OPFS Limitations

Safari limits OPFS file handles to ~250, which is sufficient for SQLite (uses ~5 handles) but problematic for PGlite (needs 300+). SQLite WASM with OPFS works on Safari. For browsers without OPFS support, fall back to IndexedDB persistence (slightly slower writes).

### 9.5 Event Log Growth

The local event log grows unboundedly. Mitigation:
- **Compaction**: Periodically compact old confirmed events into a state snapshot. Delete events before the snapshot.
- **Retention window**: Keep only the last N confirmed events locally. Older events are available on the server.
- **Lazy loading**: Don't load the entire event log on startup. Load only events after the last snapshot.

## 10. Comparison: Online-First vs Offline-First

| Aspect | Online-First | Offline-First (Recommended) |
|--------|-------------|---------------------------|
| Write path | Client → server → local | Client → local → server (async) |
| Read path | Server QueryDb (initial) + subscription (live) | Local SQLite (always) |
| Offline writes | Fallback mode, different code path | Same code path as online |
| UI latency | Network round-trip | <1ms (local) |
| Complexity | Two code paths (online/offline) | One code path |
| Data consistency | Server is authority, client is cache | Local log is authority, server is peer |
| Conflict resolution | Not needed (server always right) | Rebase on sync |
| First paint | After server query completes | After local SQLite opens (~50ms) |

The offline-first approach is strictly better for UX. The online-first approach is simpler only if you never need offline support — but adding offline support later means rewriting the entire data layer.

## 11. Implementation Roadmap

### Phase 1: Foundation
- SQLite WASM ReScript bindings (wa-sqlite + OPFS)
- EventLog module (append, query, confirm/reject)
- Shared package extraction (event types, projections, decide/reduce)

### Phase 2: Local-First Core
- Projector module (apply actions to SQLite state tables)
- CommandHandler (decide + append + project)
- Basic React hooks (useQuery with manual invalidation, useDispatch)

### Phase 3: Sync Engine
- Pull (catch-up query via GraphQL)
- Push (mutation via GraphQL)
- Subscribe (GraphQL subscription for live events)
- Rebase algorithm

### Phase 4: Production Readiness
- Event log compaction / snapshots
- Multi-tab coordination (SharedWorker)
- OPFS → IndexedDB fallback
- Error handling, retry logic, connection management

### Phase 5: DX Improvements
- Reactive query engine (SQLite update hooks)
- DevTools (event log inspector, sync status)
- Code generation for React hooks from projection specs

## 12. Conclusion

A ReScript-based offline-first client that reuses Reventless backend code is both feasible and architecturally clean. The key is treating the client as a peer with its own event log — not as a cache of server state. By always writing locally first and syncing asynchronously, the online and offline code paths are identical, yielding a genuinely offline-first architecture.

The approach is structurally identical to LiveStore's architecture. The advantage of building it natively in ReScript is full code reuse with the backend (same `decide`, `reduce`, `project` functions, same event types, same sury schemas) without needing to bridge between TypeScript/Effect Schema and ReScript/sury. The total new code (~800 lines of ReScript + ~100 lines of SQLite bindings) is manageable, with the sync engine's rebase algorithm being the most complex piece.

The existing Reventless infrastructure (AppSync for GraphQL, EventTopic for fan-out, DcbEventLog for storage) provides the backend half. The planned GraphQL subscription support feeds directly into the client's live event stream. No new backend infrastructure is needed beyond the Sync API component already described in the LiveStore integration analysis.
