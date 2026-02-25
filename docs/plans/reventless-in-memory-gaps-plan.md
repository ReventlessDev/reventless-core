# reventless-in-memory: Gap Analysis & Implementation Plan

**Status**: P0 Complete, P1+ pending
**Date**: 2026-02-25
**Updated**: 2026-02-25 — P0 GraphQL server implemented

---

## 1. Gap Analysis

### What is implemented

The `reventless-in-memory` package satisfies the full `ReventlessSpec.Platform.T` interface:

| Component | Status | Notes |
|-----------|--------|-------|
| `Aggregate_Builder` | ✅ Complete | EventLog, CommandTopic, EventTopic, Bus-based fan-out |
| `ReadModel_Builder` | ✅ Complete | EventCollector (bus-based), QueryDb (in-memory dict) |
| `ExtensionPoint_Builder` | ✅ Complete | Bus-based command/event routing |
| `Task_Builder` | ✅ Complete | No-op bucket, callback extraction works |
| `Counter_Builder` | ⚠️ No-op | `addToCounterTarget` does nothing |
| `StateChangeSlice_Builder` | ✅ Complete | Delegates to core; no platform adapter needed |
| `StateViewSlice_Builder` | ✅ Complete | Delegates to core; no platform adapter needed |
| `DcbEventLog_Builder` | ✅ Complete | In-memory array with optimistic concurrency |

### What is missing / incomplete

| Component | AWS Equivalent | In-memory Status | Priority |
|-----------|---------------|-----------------|----------|
| **GraphQL API server** | AppSync | No-op — no mutations, no queries exposed | **P0** |
| **QueryDb GraphQL resolvers** | `QueryDbResolvers_AppSync` | Uses `NoResolvers` — read model data never queryable via API | **P0** |
| **QueryEngine** | `QueryEngine_DynamoDb` | Always returns `[]` — extension/side-effect queries always empty | P1 |
| **Counter** | `CounterHandler_DynamoDbStream` | No-op — counters never increment | P2 |
| **Scheduler** | `ScheduledPublisher_CloudWatchEvents` | No-op in `SideEffectHandler`; no in-memory timer | P2 |
| **Heartbeat runner** | `HeartbeatRunner_CloudWatchEvents` | Missing entirely | P3 |
| **SideEffectHandler** (real) | Per-handler Lambda | All ops no-op | P3 |
| **ForeignReadModel_Builder** | Cross-plugin DynamoDB | Not implemented | P4 |
| **Cloner** | Fargate-based | Not needed for testing | — |

---

## 2. P0: Shared GraphQL Server (Mutations + Queries)

### Overview

In AWS, AppSync is a single GraphQL endpoint that handles both:
- **Mutations** — via `CommandGeneratorResolvers_AppSync`, one per Aggregate
- **Queries** — via `QueryDbResolvers_AppSync`, one per ReadModel

Both live in the **same schema**. A GraphQL server cannot have two separate schemas for Query and Mutation — they must be combined into one.

This means the in-memory implementation needs a **single shared GraphQL server per Platform instance** that both `CommandGeneratorResolvers_GraphQL` and `QueryDbResolvers_GraphQL` register into.

### Library: graphql-yoga

**Decision**: Use [`graphql-yoga`](https://the-guild.dev/graphql/yoga-server) with hand-written ReScript bindings in a new `rescript-graphql-yoga` package.

**Why not ResGraph**: ResGraph uses annotation-based, code-generation-first schema definition. Our schema is built *dynamically* — mutations come from `Behavior.resolverConfig.fields`, queries come from `ReadModel.Spec.name` and `config.indexes`. ResGraph cannot accommodate this pattern.

**Why graphql-yoga**: Lightweight, modern, no extra HTTP framework needed, programmatic schema building via `graphql-js`.

---

## 3. Step 1: `rescript-graphql-yoga` package

New package at `reventless/rescript-graphql-yoga/`.

### `package.json`
```json
{
  "name": "@reventlessdev/rescript-graphql-yoga",
  "version": "1.0.0-alpha.0",
  "license": "MIT",
  "dependencies": {
    "graphql": "^16.0.0",
    "graphql-yoga": "^5.0.0"
  },
  "devDependencies": {
    "rescript": "^12.1.0"
  },
  "publishConfig": {
    "registry": "https://npm.pkg.github.com"
  }
}
```

### `rescript.json`
```json
{
  "name": "@reventlessdev/rescript-graphql-yoga",
  "namespace": "RescriptGraphqlYoga",
  "sources": [{ "dir": "src", "subdirs": true }]
}
```

### `src/GraphqlYoga.res` — minimal bindings

```rescript
// ─── graphql-js (schema building) ─────────────────────────────────────────

type graphqlSchema

// Build schema from SDL string. Used to define types programmatically.
@module("graphql")
external buildSchema: string => graphqlSchema = "buildSchema"

// ─── Resolver types ────────────────────────────────────────────────────────

// Root-level resolver: (parent, args) => promise<JSON.t>
type resolverFn = (JSON.t, JSON.t) => promise<JSON.t>

// Field resolver on a type (for idResolvers / idsResolvers)
type fieldResolverFn = (JSON.t, JSON.t) => promise<JSON.t>

type resolverMap = {
  "Query": dict<resolverFn>,
  "Mutation": dict<resolverFn>,
}

// ─── graphql-yoga ─────────────────────────────────────────────────────────

type yoga

@module("graphql-yoga")
external createYoga: {
  "schema": graphqlSchema,
  "resolvers": resolverMap,
  "graphiql": bool,
  "logging": bool,
} => yoga = "createYoga"

// yoga.handle is a Node.js-compatible (req, res) => Promise<void> function.
// Pass it directly to http.createServer.
@send external handle: (yoga, 'req, 'res) => promise<unit> = "handle"

// ─── Node http ────────────────────────────────────────────────────────────

type httpServer

@module("http")
external createServer: (('req, 'res) => promise<unit>) => httpServer = "createServer"

@send external listen: (httpServer, int, unit => unit) => unit = "listen"
@send external close: (httpServer, option<unit => unit>) => unit = "close"
```

> **Note on resolvers**: `graphql-yoga` accepts a `resolvers` object alongside `schema` when the schema is built from SDL (`buildSchema`). This separates the type definitions (SDL) from the resolver functions.

---

## 4. Step 2: `GraphQL_Server.res` — shared server registry

Location: `reventless/reventless-in-memory/src/adapter/GraphQL_Server.res`

This module holds a **global registry** of mutation and query resolver functions. Both `CommandGeneratorResolvers_GraphQL` and `QueryDbResolvers_GraphQL` write into it during "deploy time". `startServer` is called once after all components are built.

```rescript
// ─── Registry ─────────────────────────────────────────────────────────────

type resolverFn = RescriptGraphqlYoga.GraphqlYoga.resolverFn

let mutationResolvers: ref<dict<resolverFn>> = ref(Dict.make())
let queryResolvers: ref<dict<resolverFn>> = ref(Dict.make())

// SDL fragments collected from all components; joined when server starts
let mutationFields: ref<array<string>> = ref([])
let queryFields: ref<array<string>> = ref([])

let registerMutations = (~sdlFields: array<string>, ~resolvers: dict<resolverFn>) => {
  mutationFields.contents = mutationFields.contents->Array.concat(sdlFields)
  resolvers->Dict.toArray->Array.forEach(((k, v)) =>
    mutationResolvers.contents->Dict.set(k, v)
  )
}

let registerQueries = (~sdlFields: array<string>, ~resolvers: dict<resolverFn>) => {
  queryFields.contents = queryFields.contents->Array.concat(sdlFields)
  resolvers->Dict.toArray->Array.forEach(((k, v)) =>
    queryResolvers.contents->Dict.set(k, v)
  )
}

// ─── Server lifecycle ──────────────────────────────────────────────────────

let activeServer: ref<option<RescriptGraphqlYoga.GraphqlYoga.httpServer>> = ref(None)

let buildSdl = () => {
  let mutations = mutationFields.contents->Array.join("\n")
  let queries =
    queryFields.contents->Array.length > 0
      ? queryFields.contents->Array.join("\n")
      : "  _noop: String"
  `
type Query {
${queries}
}
type Mutation {
${mutations}
}
`
}

let start = (~port: int=4000, ()) => {
  open RescriptGraphqlYoga.GraphqlYoga
  let schema = buildSchema(buildSdl())
  let resolvers = {
    "Query": queryResolvers.contents,
    "Mutation": mutationResolvers.contents,
  }
  let yoga = createYoga({
    "schema": schema,
    "resolvers": resolvers,
    "graphiql": true,
    "logging": false,
  })
  let server = createServer(yoga->handle)
  server->listen(port, () => Console.log(`[GraphQL] Listening on http://localhost:${port->Int.toString}/graphql`))
  activeServer.contents = Some(server)
}

let stop = () =>
  switch activeServer.contents {
  | Some(server) =>
    server->close(None)
    activeServer.contents = None
  | None => ()
  }

// Reset state (for test isolation between test suites)
let reset = () => {
  mutationResolvers.contents = Dict.make()
  queryResolvers.contents = Dict.make()
  mutationFields.contents = []
  queryFields.contents = []
}
```

---

## 5. Step 3: `CommandGeneratorResolvers_GraphQL.res`

Location: `reventless/reventless-in-memory/src/adapter/CommandGenerator/CommandGeneratorResolvers_GraphQL.res`

Satisfies `CommandGenerator_Adapter.Resolvers`. Registers mutations into `GraphQL_Server` during `make`. The resolver closure references a `handlerRef` that is populated when `handleResolversEvent` is called later.

```rescript
open Reventless

type api = unit
type runtimeParts = RuntimeEnvironment_InMemory.parts

let handleResolversEvent = (generateCommand: CommandGenerator.commandGenerator) =>
  // Satisfies the module type — in-memory tests don't go through this HTTP path.
  // The actual HTTP resolvers call generateCommand directly via handlerRef below.
  Pulumi.Output.make((event, _context) => event->generateCommand)

let make: CommandGenerator_Adapter.resolversMaker<unit, runtimeParts> = (
  ~name as _,
  ~api as _,
  ~fields,
  ~runtime as _,
  ~resources as _,
  ~opts as _,
) => {
  // handlerRef is shared between the SDL resolver closure and handleResolversEvent.
  // It is set when the Aggregate wires its CommandTopic (inside Output.apply, which
  // runs synchronously in Pulumi mock mode before the first test executes).
  let handlerRef: ref<option<CommandGenerator.commandGenerator>> = ref(None)

  // SDL fragment: one field per resolver config entry.
  // Arguments are generic (JSON scalar) since types are unknown at schema-build time.
  let sdlFields = fields->Array.map(field => `  ${field}(id: ID, args: String): String`)

  let makeResolver = (fieldName: string): GraphQL_Server.resolverFn =>
    async (_root, args) => {
      // Mirror what AppSync VTL does: derive command name from field name.
      let commandName = switch fieldName->String.split("_") {
      | [_agg, cmd] => cmd->String.capitalize
      | _ => fieldName->String.capitalize
      }
      let payload: CommandGenerator.payload = {
        command: commandName,
        arguments: args->Obj.magic,
        meta: {ip: [], user: "local", info: `Mutation.${fieldName}`},
      }
      switch handlerRef.contents {
      | Some(generateCommand) =>
        let result = await generateCommand(payload)
        result->JSON.Encode.string
      | None =>
        JsError.throwWithMessage(
          `CommandGeneratorResolvers_GraphQL: handler not yet set for field '${fieldName}'`,
        )
      }
    }

  let resolvers = Dict.make()
  fields->Array.forEach(f => resolvers->Dict.set(f, makeResolver(f)))

  GraphQL_Server.registerMutations(~sdlFields, ~resolvers)

  {resources: []}
}
```

**Wire into `Aggregate_Builder.res`**: replace `CommandGeneratorResolvers_InMemory` with `CommandGeneratorResolvers_GraphQL`.

---

## 6. Step 4: QueryDb storage registry on Bus

Before `QueryDbResolvers_GraphQL` can resolve queries, it needs access to the actual in-memory storage operations. The `QueryDb_Adapter.resolversMaker` only receives `~dataSourceName` (a string, the DynamoDB table name in AWS — `""` in-memory), not the storage operations themselves.

**Solution**: extend `InMemory_Bus.T` with a QueryDb storage registry. `QueryDbStorage_InMemory.Make(Bus)` registers its ops at creation time; `QueryDbResolvers_GraphQL.Make(Bus)` looks them up at query time.

### `InMemory_Bus.res` additions

```rescript
// In module type T — add:
let registerQueryDb: (string, Reventless.QueryDb_Adapter.operations) => unit
let getQueryDb: string => option<Reventless.QueryDb_Adapter.operations>

// In Make() — add:
let queryDbRegistry: ref<dict<Reventless.QueryDb_Adapter.operations>> = ref(Dict.make())
let registerQueryDb = (name, ops) => queryDbRegistry.contents->Dict.set(name, ops)
let getQueryDb = name => queryDbRegistry.contents->Dict.get(name)
```

### `QueryDbStorage_InMemory.res` — register ops

After creating the `ops` record, register it on the Bus:

```rescript
// At the end of make, before returning:
Bus.registerQueryDb(name, ops)
```

Also add a `scanAll` function to return all stored items (needed for `every{Name}` queries):

```rescript
// Expose via Bus registry as part of ops — or add a dedicated scan function.
// Simplest: extend the dict with a sentinel key "*" that returns all values.
// Or: have QueryDbStorage maintain a parallel array for scan.
let allItems: ref<array<JSON.t>> = ref([])

// Augment save:
let save = async (id, state, _saveMode, _ttl) => {
  store.contents->Dict.set(id, [state])
  // Keep allItems in sync for scan:
  allItems.contents = store.contents->Dict.values->Array.flatMap(v => v)
  Ok()
}
// Similarly for saveBatch, delete, deleteBatch.

// Register extended ops in Bus:
Bus.registerQueryDb(name, {ops with scanAll: () => allItems.contents})
```

> **Note**: `QueryDb_Adapter.operations` does not have a `scanAll` field. To avoid changing the spec, the scan capability can be stored as a separate registry entry on the Bus, or `QueryDbStorage_InMemory` can be made into a `Make(Bus)` functor and register a separate scan function.

**Recommended**: Add a parallel `registerQueryDbScan` to the Bus:

```rescript
// InMemory_Bus.T:
let registerQueryDbScan: (string, unit => array<JSON.t>) => unit
let getQueryDbScan: string => option<unit => array<JSON.t>>
```

---

## 7. Step 5: `QueryDbResolvers_GraphQL.Make(Bus)`

Location: `reventless/reventless-in-memory/src/adapter/QueryDb/QueryDbResolvers_GraphQL.res`

Satisfies `QueryDb_Adapter.Resolvers`. Registers query fields into `GraphQL_Server`.

```rescript
module Make = (Bus: InMemory_Bus.T) => {
  open ReventlessSpec.ReadModel

  type api = unit
  type role = unit

  let make: Reventless.QueryDb_Adapter.resolversMaker<unit, unit> = (
    ~name,
    ~api as _,
    ~apiRole as _,
    ~dataSourceName as _,
    ~indexes,
    ~subIdField,
    ~idResolverConfigs as _,   // cross-read-model resolvers — deferred to P4
    ~idsResolverConfigs as _,  // cross-read-model resolvers — deferred to P4
    ~opts as _,
  ) => {
    // ── Main query: get by id ────────────────────────────────────────────────
    // AWS: Query.{name}(id: ID!) or Query.{name}(id: ID!, {sortField}: String)
    let queryName = name->String.uncapitalize
    let byIdField =
      switch subIdField {
      | Some(sf) => `  ${queryName}(id: ID!, ${sf}: String): [String]`
      | None => `  ${queryName}(id: ID!): [String]`
      }

    let byIdResolver: GraphQL_Server.resolverFn = async (_root, args) => {
      let id = args->Obj.magic->Dict.get("id")->Option.getOr("")
      switch Bus.getQueryDb(name) {
      | Some(ops) =>
        let items = (await ops.load(id))->Result.getOr([])
        items->JSON.Encode.array(x => x)
      | None => []->JSON.Encode.array(x => x)
      }
    }

    // ── List all: every{Name} ────────────────────────────────────────────────
    // AWS: Query.every{Name}: [{state}]
    let everyName = "every" ++ name
    let everyField = `  ${everyName}: [String]`
    let everyResolver: GraphQL_Server.resolverFn = async (_root, _args) => {
      switch Bus.getQueryDbScan(name) {
      | Some(scanAll) => scanAll()->JSON.Encode.array(x => x)
      | None => []->JSON.Encode.array(x => x)
      }
    }

    // ── By-id-list: {name}ById(id) — only when subId is configured ──────────
    // AWS: Query.{name}ById(id: ID!): [{state}]
    let byIdListFields = switch subIdField {
    | Some(_) => [`  ${queryName}ById(id: ID!): [String]`]
    | None => []
    }
    let byIdListResolvers: array<(string, GraphQL_Server.resolverFn)> = switch subIdField {
    | Some(_) =>
      let resolver: GraphQL_Server.resolverFn = async (_root, args) => {
        let id = args->Obj.magic->Dict.get("id")->Option.getOr("")
        switch Bus.getQueryDb(name) {
        | Some(ops) =>
          let items = (await ops.load(id))->Result.getOr([])
          items->JSON.Encode.array(x => x)
        | None => []->JSON.Encode.array(x => x)
        }
      }
      [(queryName ++ "ById", resolver)]
    | None => []
    }

    // ── Index queries: {name}By{Index}(value: String!) ───────────────────────
    // AWS: Query.{name}By{Index}(value: String!): [{state}]
    // In-memory: scan all and filter by index field value.
    let indexFields = indexes->Array.map(({index}) =>
      `  ${queryName}By${index->String.capitalize}(${index}: String!): [String]`
    )
    let indexResolvers: array<(string, GraphQL_Server.resolverFn)> = indexes->Array.map(
      ({index, idField}) => {
        let fieldName = queryName ++ "By" ++ index->String.capitalize
        let idF = idField->Option.getOr(index)
        let resolver: GraphQL_Server.resolverFn = async (_root, args) => {
          let value = args->Obj.magic->Dict.get(index)->Option.getOr("")
          switch Bus.getQueryDbScan(name) {
          | Some(scanAll) =>
            scanAll()
            ->Array.filter(item =>
              item->Obj.magic->Dict.get(idF)->Option.map(v => v == value)->Option.getOr(false)
            )
            ->JSON.Encode.array(x => x)
          | None => []->JSON.Encode.array(x => x)
          }
        }
        (fieldName, resolver)
      },
    )

    // ── Register all query fields ─────────────────────────────────────────────
    let allFields =
      [byIdField, everyField]
      ->Array.concat(byIdListFields)
      ->Array.concat(indexFields)

    let resolvers = Dict.make()
    resolvers->Dict.set(queryName, byIdResolver)
    resolvers->Dict.set(everyName, everyResolver)
    byIdListResolvers->Array.forEach(((k, v)) => resolvers->Dict.set(k, v))
    indexResolvers->Array.forEach(((k, v)) => resolvers->Dict.set(k, v))

    GraphQL_Server.registerQueries(~sdlFields=allFields, ~resolvers)

    // resourcesMaker: cross-read-model resolvers — not implemented yet (P4)
    {
      resources: [],
      resourcesMaker: _ => [],
    }
  }
}
```

**Wire into `ReadModel_Builder.res`**: replace `Reventless.QueryDb_Adapter.NoResolvers(QueryDbStorage_InMemory)` with `QueryDbResolvers_GraphQL.Make(Bus)`.

---

## 8. Step 6: Server startup in `Platform.res` and `TestRunner.res`

### `Platform.Make(~port=4000, ())` — start server after all components built

```rescript
// At the bottom of Platform.Make, after all module bindings:
// Start the shared GraphQL server once all resolvers are registered.
// In Pulumi mock mode, all Output.apply callbacks run synchronously, so
// all registrations complete before Make() returns.
let () = GraphQL_Server.start(~port, ())
```

The port defaults to `4000` and is configurable:
```rescript
module Make = (~port: int=4000, ()): ReventlessSpec.Platform.T => { ... }
```

### `TestRunner.res` — stop server in afterAll

```rescript
let stopGraphQLServer = () => GraphQL_Server.stop()

// Reset between test suites (if using multiple Platform.Make() calls):
let resetGraphQLServer = () => GraphQL_Server.reset()
```

Usage in tests:
```rescript
afterAll(() => {
  TestRunner.stopGraphQLServer()
})
```

---

## 9. How the two-phase handler wiring works

`CommandGenerator_Builder.Make` has two distinct phases:

1. **Deploy time** (`make` / `connect`): `CommandGeneratorResolvers_GraphQL.make(~fields, ...)` is called. SDL fields and resolver closures are registered in `GraphQL_Server`. Each resolver closure captures a `handlerRef` that is initially `None`.

2. **Runtime** (`makeHandler`): `CommandGeneratorResolvers_GraphQL.handleResolversEvent(generateCommand)` is called. This sets `handlerRef.contents = Some(generateCommand)`.

In Pulumi mock mode, both phases run synchronously (inside `Output.apply` chains that resolve immediately). By the time `Platform.Make()` returns and `GraphQL_Server.start()` is called, all `handlerRef`s are populated.

**Important**: `handleResolversEvent` returns a `Pulumi.Output.t<eventHandler<'context>>` — this is the runtime Lambda handler in AWS. In-memory we satisfy this type but the HTTP path bypasses it entirely — the `handlerRef` is used directly by the GraphQL resolver instead.

---

## 10. P1: QueryEngine — Real In-Memory Implementation

The `QueryEngine` is used by `ExtensionPoint_Operations`, `Extension_Operations`, and `SideEffectHandler_Callback` to query read model state. Currently always returns `[]`.

With the Bus-based storage registry (added in Step 4), `QueryEngine_InMemory` can now look up storage by `readModelName`:

```rescript
// QueryEngine_InMemory.Make(Bus)
module Make = (Bus: InMemory_Bus.T) => {
  let make: Reventless.QueryDb_Adapter.queryEngineMaker = _allQueryDbs =>
    Pulumi.Output.make({
      ReventlessSpec.QueryEngine.scan: async (~readModelName, ~filterConfigs as _, ~limit as _) =>
        switch Bus.getQueryDbScan(readModelName) {
        | Some(scanAll) => scanAll()
        | None => []
        },
      query: async (
        ~readModelName,
        ~key=?,
        ~id,
        ~subIdConfig as _=?,
        ~filterConfigs as _=?,
        ~ascending as _=?,
        ~limit as _=?,
      ) =>
        switch Bus.getQueryDb(readModelName) {
        | Some(ops) => (await ops.load(key->Option.getOr(id)))->Result.getOr([])
        | None => []
        },
    })
}
```

Wire in `Platform.res`: replace the current `QueryEngine_InMemory` with `QueryEngine_InMemory.Make(Bus)`.

---

## 11. P2: Counter — Real Implementation

`CounterHandler_InMemory.addToCounterTarget` is a no-op. Replace with an actual counter dict. Since `CounterHandler_InMemory` has no functor (no `Bus` parameter), use a module-level ref:

```rescript
let counterStore: ref<dict<int>> = ref(Dict.make())

let addToCounterTarget: Counter_Adapter.addToCounterTarget = async counterTargetRef => {
  let key = counterTargetRef.id ++ ":" ++ counterTargetRef.fieldName
  let current = counterStore.contents->Dict.get(key)->Option.getOr(0)
  counterStore.contents->Dict.set(key, current + counterTargetRef.inc)
}

let reset = () => counterStore.contents = Dict.make()
```

Expose `reset` via `TestRunner.res`.

---

## 12. P2: Scheduler — In-Memory Implementation

Create `Scheduler_InMemory.res` using Node.js timers:

```rescript
type timerHandle
@val external setInterval: (unit => unit, int) => timerHandle = "setInterval"
@val external clearInterval: timerHandle => unit = "clearInterval"

let activeTimers: ref<dict<timerHandle>> = ref(Dict.make())

let rateToMs = (rate: ReventlessSpec.Schedule.rate) =>
  switch rate {
  | Minutes(n) => n * 60 * 1000
  | Hours(n) => n * 60 * 60 * 1000
  | Daily => 24 * 60 * 60 * 1000
  | _ => 60 * 1000
  }

let make = (publishFn: string => promise<unit>): ReventlessSpec.Scheduler.operations => {
  createSchedule: async schedule => {
    let handle = setInterval(() => publishFn(schedule.name)->ignore, rateToMs(schedule.rate))
    activeTimers.contents->Dict.set(schedule.name, handle)
  },
  deleteSchedule: async name => {
    switch activeTimers.contents->Dict.get(name) {
    | Some(h) =>
      clearInterval(h)
      activeTimers.contents->Dict.delete(name)
    | None => ()
    }
  },
}
```

Wire into `SideEffectHandler_InMemory.res`.

---

## 13. Summary: Implementation Order

| Phase | Item | Status | Notes |
|-------|------|--------|-------|
| P0 | `rescript-graphql-yoga` package | ✅ Done | New package; graphql + graphql-yoga bindings |
| P0 | `GraphQL_Server.res` | ✅ Done | Shared registry + single server startup |
| P0 | `CommandGeneratorResolvers_GraphQL.res` | ✅ Done | Mutations; replaces `_InMemory` no-op |
| P0 | `QueryDbResolvers_GraphQL.Make(Bus)` | ✅ Done | Queries (getById, listAll, byIndex) |
| P0 | Bus: `registerQueryDb/Scan`, storage: `scanAll` | ✅ Done | Prerequisite for QueryDb resolver + QueryEngine |
| P0 | `AggregateRuntime_Builder_InMemory.forCommandGenerator` | ✅ Done | Now calls connect() to register SDL |
| P1 | `QueryEngine_InMemory.Make(Bus)` | Pending | Real scan/query via Bus registry |
| P2 | `CounterHandler_InMemory` (real) | Pending | Replace no-op |
| P2 | `Scheduler_InMemory` | Pending | Node.js timer-based |
| P3 | `HeartbeatRunner_InMemory` | Pending | `setInterval`-based |

### P0 Implementation Notes

- `QueryDbStorage_InMemory` was converted from a plain module to a `Make(Bus)` functor
  to enable Bus registration during component construction.
- `Counter_Builder` and `ReadModel_Builder` both instantiate `QueryDbStorage_InMemory.Make(Bus)`
  internally.
- `Platform.Make` starts the GraphQL server on port 4000 (hardcoded — module functors
  don't support labeled args). The port could be made configurable via a `Config` module arg
  in the future.
- `CommandGeneratorResolvers_GraphQL` uses a module-level `pending` slot for the
  generateCommand function: `handleResolversEvent` fills it, `make` consumes it.
  This is safe because Pulumi mock mode is synchronous and the two calls are always
  back-to-back for each aggregate.

---

## 14. Files to Create / Modify

### New files

```
reventless/rescript-graphql-yoga/
├── package.json
├── rescript.json
└── src/GraphqlYoga.res

reventless/reventless-in-memory/src/adapter/
├── GraphQL_Server.res                               ← shared server registry
├── CommandGenerator/
│   └── CommandGeneratorResolvers_GraphQL.res        ← replaces _InMemory no-op
├── QueryDb/
│   └── QueryDbResolvers_GraphQL.res                 ← new; Make(Bus) functor
└── Scheduler/
    └── Scheduler_InMemory.res                       ← new
```

### Modified files

```
reventless/reventless-in-memory/src/adapter/InMemory_Bus.res
  → Add: registerQueryDb, getQueryDb, registerQueryDbScan, getQueryDbScan

reventless/reventless-in-memory/src/adapter/QueryDb/QueryDbStorage_InMemory.res
  → Register ops + scan fn in Bus; maintain allItems array for scan

reventless/reventless-in-memory/src/adapter/QueryEngine/QueryEngine_InMemory.res
  → Become Make(Bus) functor; real scan/query via Bus registry

reventless/reventless-in-memory/src/adapter/Counter/CounterHandler_InMemory.res
  → Replace no-op with real counter dict

reventless/reventless-in-memory/src/components/Aggregate_Builder.res
  → Use CommandGeneratorResolvers_GraphQL instead of _InMemory

reventless/reventless-in-memory/src/components/ReadModel_Builder.res
  → Use QueryDbResolvers_GraphQL.Make(Bus) instead of NoResolvers(QueryDbStorage_InMemory)

reventless/reventless-in-memory/src/TestRunner.res
  → Add stopGraphQLServer(), resetGraphQLServer()

reventless/reventless-in-memory/src/Platform.res
  → Accept ~port parameter; call GraphQL_Server.start after all components built
  → Use QueryEngine_InMemory.Make(Bus)

reventless/reventless-in-memory/rescript.json
  → Add "@reventlessdev/rescript-graphql-yoga" to dependencies
```
