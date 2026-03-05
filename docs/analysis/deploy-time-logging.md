# Deploy-Time Logging Analysis

**Created:** 2026-03-05

**Context:** The effect-logger-and-request-context plan (Phase A+B complete) migrated runtime callback
logging from `Console.*` to `Effect.logInfo`/`Effect.logError`. Deploy-time logging was explicitly
kept as `Console.*` because no Effect pipeline is available. This analysis inventories all deploy-time
logging, evaluates its current state, and explores whether a similar structured approach could improve it.

---

## What Is "Deploy Time"?

Deploy-time code runs during `pulumi up` (or during in-memory platform setup). It executes in two contexts:

1. **Pulumi Output.apply callbacks** — synchronous code inside `Output.apply(value => ...)` that runs
   when Pulumi resolves an Output value. Handler registration, resource wiring, and diagnostics happen here.

2. **Builder/constructor code** — synchronous module-level code that runs when ReScript modules are
   instantiated during Pulumi program evaluation. Component builders, schema stitching, and adapter
   setup happen here.

Neither context has an Effect pipeline — they run as plain synchronous JavaScript during Pulumi's
resource graph construction phase.

---

## Inventory

### Category 1: Handler Registration Diagnostics

These log messages trace which runtime handlers are registered for which URNs during `Output.apply`.
They are the primary deploy-time diagnostic tool for debugging handler routing.

| File | Line | Level | Message Pattern |
|------|------|-------|-----------------|
| `AggregateRuntime_Builder_Common.res` | 144 | info | `***** forCommandGenerator {name}: set handler for {infos}` |
| `AggregateRuntime_Builder_Common.res` | 174 | info | `***** forCommandTopic {name}: set handler for {urn}` |
| `AggregateRuntime_Builder_Common.res` | 213 | info | `***** forEventCollector {name}: set handler for {urns}` |
| `EventCollectorRuntime_Builder_Single.res` | 75 | info | `validateParent: parent {name} type: {type}` |
| `EventCollectorRuntime_Builder_Single.res` | 145 | info | `***** forEventCollector {name}: set handler for {urns}` |

**Note:** The `aggregateHandler` and `eventCollectorHandler` dispatch functions (lines 49/62/68 and 56)
now use `Effect.logInfo`/`Effect.logWarning` with `->Effect.runSync` — these run at Lambda runtime,
not deploy time.

### Category 2: Pulumi Infrastructure Setup

These log during `pulumi up` when AWS resources are being configured.

| File | Line | Level | Message Pattern |
|------|------|-------|-----------------|
| `Util_DynamoDb.res` | 36 | info | `{module}: enableTimeToLive for {table}` |
| `Util_DynamoDb.res` | 71 | info | `{module}: enablePointInTimeRecovery for {table}` |
| `Util_DynamoDbStream.res` | 45 | info | `{module}: enableStream for {table}` |
| `Util_SNS.res` | 25 | error | Topic lookup failure (bare error object) |
| `Util_SNS_FIFO.res` | 18 | error | Topic lookup failure (bare error object) |

### Category 3: Event/Command Channel Wiring

These trace SNS subscription creation and EventCollector channel connections.

| File | Line | Level | Message Pattern |
|------|------|-------|-----------------|
| `EventCollectorChannel_Helpers.res` | 51 | info | `subscribeToSnsTopic: {name}, {resource}` |
| `EventCollectorChannel_Helpers.res` | 59 | info | `created SNS subscription: {id}, {name}` (inside Output.apply) |
| `EventCollectorChannel_Helpers.res` | 68 | error | SNS subscription error |
| `EventCollectorChannel_Helpers.res` | 99 | info | `connectLambda {name}: {snsTopicCount} SNS topics` |
| `EventCollectorChannel_Helpers.res` | 103 | info | `connectLambda {name}: resources: {resources}` |
| `EventCollectorChannel_DynamoDbStream.res` | 40 | info | Stream source mapping info (4 args) |
| `EventTopic.res` | 74 | info | `{description}: {topics}` (inside Output.apply) |

### Category 4: Plugin & Resource Discovery

These log during plugin wiring when resolving cross-plugin resources.

| File | Line | Level | Message Pattern |
|------|------|-------|-----------------|
| `Plugin_Helpers.res` | 66 | error | Plugin resource parsing error |
| `Plugin_Helpers.res` | 73 | error | Plugin resource lookup error |
| `Plugin_Helpers.res` | 86 | error | `Couldn't find Plugin {name}` |
| `Util_Adapter.res` | 40 | error | Resource resolution error (inside Output.apply) |
| `Util_Adapter.res` | 52 | error | Missing service error |
| `Util_AdapterRuntime.res` | 24, 35 | error | Adapter runtime errors |
| `Util_QueryDb.res` | 6 | error | `Couldn't find QueryDb {name}` |
| `Adapter.res` | 63 | debug | `resource: {resolved}` (inside Output.apply) |

### Category 5: GraphQL Schema Construction

These trace schema stitching during deploy (or in-memory setup).

| File | Line | Level | Message Pattern |
|------|------|-------|-----------------|
| `GraphQL_Stitcher.res` | 75 | warn | `[GraphQL_Stitcher] Duplicate type — skipped: {name}` |
| `GraphQL_Stitcher.res` | 91 | warn | `[GraphQL_Stitcher] Duplicate mutation field — skipped: {name}` |
| `GraphQL_Stitcher.res` | 107 | warn | `[GraphQL_Stitcher] Duplicate query field — skipped: {name}` |
| `GraphQL_SchemaInspector.res` | 99-120 | info | Full schema diagnostic dump (types, mutations, queries, SDL) |

### Category 6: Plugin Extension & Cross-Plugin Communication

These log during deploy-time extension point wiring.

| File | Line | Level | Message Pattern |
|------|------|-------|-----------------|
| `PluginConnectExtension_Builder.res` | 18 | info | Cross-plugin extension connection |
| `PluginConnectExtension_Builder.res` | 26 | info | Extension connection details |
| `PluginConnectExtension_Builder.res` | 30 | info | Connection mapping |
| `PluginConnectExtension_Builder.res` | 42 | info | Extension point listing |
| `PluginConnectExtension_Builder.res` | 50 | info | Extension point details |
| `PluginConnectExtension_Builder.res` | 54 | info | Extension point mapping |

### Category 7: Builder Decode Errors

These log inside builder-constructed handlers when event/command deserialization fails. They run
at Lambda runtime but are defined in builder code — they sit in `Effect.sync`/`Stream.mapEffect`
closures that are captured at deploy time.

| File | Line | Level | Message Pattern |
|------|------|-------|-----------------|
| `AutomationSlice_Builder.res` | 83 | error | `AutomationSlice: Failed to decode event: {exn}` |
| `AutomationSlice_Builder.res` | 98 | error | `AutomationSlice({name}): publishJsons not yet resolved` |
| `OutboundTranslationSlice_Builder.res` | 83 | error | `OutboundTranslationSlice: Failed to decode event: {exn}` |
| `OutboundTranslationSlice_Builder.res` | 98 | error | `OutboundTranslationSlice({name}): publishJsons not yet resolved` |
| `StateChangeSlice_Builder.res` | 20 | error | `Couldn't decode command {cmd}: {err}` |
| `StateViewSlice_Builder.res` | 75 | error | `StateViewSlice: Failed to decode event: {exn}` |

### Category 8: In-Memory Platform (Local Development Only)

These provide rich diagnostics during local development. Not relevant to production deploy.

| File | Count | Prefix | Purpose |
|------|-------|--------|---------|
| `GraphQL_Server.res` | ~25 | `[GraphQL]` | Server startup, schema rebuild, SDL dump, diagnostics |
| `MCP_Server.res` | ~15 | `[MCP]` | Tool/resource registration, request tracing, diagnostics |
| `InMemory_Bus.res` | 1 | (none) | No command handler warning (gated by `silent` flag) |

### Category 9: Miscellaneous Deploy-Time

| File | Line | Level | Message Pattern |
|------|------|-------|-----------------|
| `Cloner.res` | 66 | info | `No ClonerRunner created — no secrets configured` |
| `Task_Builder.res` | 66, 71 | info | `No SideEffectHandler to create/delete schedule` |
| `Validation.res` | 34 | error | Validation error |
| `OutputLogger.res` | 4, 8 | info/error | Output value debugging |
| `Projection.res` | 17, 141, 269-297, 335-366 | mixed | Projection optimization and execution logging |

---

## Current Problems

### 1. No Consistent Format

Deploy-time log messages use at least five different prefix conventions:
- `***** forComponentType`: handler registration
- `----- aggregateHandler:`: handler dispatch (now Effect, but was Console)
- `[GraphQL_Stitcher]`: bracketed module name
- `${__MODULE__}:`: ReScript module path
- No prefix at all: many ad-hoc messages

This makes it hard to filter or search deploy logs for a specific concern.

### 2. No Level Distinction

All deploy-time logs use `Console.log` regardless of severity. Errors (`Console.error`), warnings
(`Console.warn`), and info (`Console.log`) are used inconsistently:
- `Util_SNS.res:25` logs an error object with `Console.log` (should be `Console.error`)
- `Plugin_Helpers.res:66` logs parse errors with `Console.log2` (should be `Console.error`)
- `Projection.res` mixes `Console.log`, `Console.warn`, and `Console.error` — correct but inconsistent
  with the rest

### 3. Inconsistent Argument Styles

Messages use `Console.log`, `Console.log2`, `Console.log3`, and `Console.log4` — some pass structured
objects as separate arguments (good for browser console, bad for CloudWatch where each arg becomes a
separate field), others use string interpolation.

### 4. No Component Context

Most messages don't identify which component or plugin they belong to. During a multi-plugin deploy,
messages from different plugins interleave with no way to trace which plugin generated which log.

### 5. Noisy by Default

Handler registration logs (`*****` prefix) fire for every registered handler. A typical plugin with
3 aggregates, 5 event collectors, and 2 command topics generates ~10 registration messages — across
10 plugins that's 100+ lines of handler registration noise. There's no way to suppress these without
modifying code.

---

## Comparison: Runtime vs Deploy-Time Logging

| Aspect | Runtime (Post Phase B) | Deploy-Time (Current) |
|--------|------------------------|----------------------|
| **Mechanism** | `Effect.logInfo/logError` | `Console.log/warn/error` |
| **Level filtering** | `Logger.minimumLogLevel` | None |
| **Structured output** | Via Effect's logger | Ad-hoc strings |
| **Correlation** | `RequestContext.correlationId` | Not applicable |
| **Testability** | Silenceable in tests | Always prints |
| **Consistency** | Unified pattern | 5+ prefix styles |

---

## Improvement Options

### Option A: Minimal — Consistent Prefixes and Correct Levels

The simplest improvement. No new infrastructure — just discipline.

**Convention:**
- All deploy-time logs use `[deploy:{component}]` prefix
- Use correct Console method: `Console.log` for info, `Console.warn` for warnings, `Console.error` for errors
- Single-string messages only (no `Console.log2/3/4` — interpolate into the string)

**Example:**
```rescript
// Before:
Console.log(`***** forCommandTopic ${name}: set handler for ${urn}`)

// After:
Console.log(`[deploy:AggregateRuntime] forCommandTopic ${name}: set handler for ${urn}`)
```

**Pros:** Zero infrastructure, easy to apply incrementally.
**Cons:** No level filtering, no structured output, still noisy.

### Option B: Deploy Logger Module

A lightweight synchronous logger module for deploy-time code. Not Effect-based — plain functions.

```rescript
// DeployLogger.res
type level = Info | Warn | Error | Debug

let minLevel: ref<level> = ref(Info)
let setMinLevel = level => minLevel := level

let shouldLog = level => {
  let levelToInt = l => switch l { | Debug => 0 | Info => 1 | Warn => 2 | Error => 3 }
  levelToInt(level) >= levelToInt(minLevel.contents)
}

let log = (~component: string, ~level: level=Info, msg: string) =>
  if shouldLog(level) {
    let levelStr = switch level { | Debug => "DEBUG" | Info => "INFO" | Warn => "WARN" | Error => "ERROR" }
    let output = `[deploy:${component}] ${levelStr}: ${msg}`
    switch level {
    | Error => Console.error(output)
    | Warn => Console.warn(output)
    | _ => Console.log(output)
    }
  }

let info = (~component, msg) => log(~component, ~level=Info, msg)
let warn = (~component, msg) => log(~component, ~level=Warn, msg)
let error = (~component, msg) => log(~component, ~level=Error, msg)
let debug = (~component, msg) => log(~component, ~level=Debug, msg)
```

**Usage:**
```rescript
// In AggregateRuntime_Builder_Common.res:
DeployLogger.info(~component="AggregateRuntime",
  `forCommandTopic ${name}: set handler for ${urn}`)

// In Util_DynamoDb.res:
DeployLogger.info(~component="DynamoDB", `enableTimeToLive for ${tableName}`)

// Suppress noisy handler registration during deploys:
DeployLogger.setMinLevel(Warn)
```

**Pros:**
- Level filtering (suppress debug/info during production deploys)
- Consistent format across all deploy-time code
- Searchable in logs: `grep "[deploy:"` or `grep "deploy:AggregateRuntime"`
- Zero new dependencies, simple synchronous functions
- Can be configured via environment variable (`DEPLOY_LOG_LEVEL`)

**Cons:**
- New module to maintain (though it's ~20 lines)
- Migration effort (though can be done incrementally)
- Slightly more verbose call sites (`DeployLogger.info(~component=..., msg)` vs `Console.log(msg)`)

### Option C: Structured JSON Output

Extends Option B with JSON-structured output for Pulumi log parsing.

```rescript
let log = (~component, ~level=Info, msg) =>
  if shouldLog(level) {
    let entry = {
      "phase": "deploy",
      "component": component,
      "level": levelToString(level),
      "message": msg,
    }
    Console.log(entry->JSON.stringifyAny->Option.getOr(""))
  }
```

**Pros:** Machine-parseable, queryable in CloudWatch Insights.
**Cons:** Pulumi already captures stdout — JSON strings inside Pulumi output look cluttered.
Not recommended unless there's a concrete log aggregation need.

---

## Recommendation

**Option B (Deploy Logger Module)** provides the best balance of improvement vs effort:

1. **Level filtering** solves the noise problem — handler registration becomes `Debug`, errors stay visible
2. **Component tags** enable filtering by subsystem
3. **Consistent format** makes deploy logs scannable
4. **Environment variable control** (`DEPLOY_LOG_LEVEL`) lets operators tune verbosity per deployment
5. **Incremental migration** — adopt file by file without breaking anything

### Suggested Log Levels by Category

| Category | Suggested Level | Rationale |
|----------|----------------|-----------|
| Handler registration (`*****`) | Debug | Noisy, only needed for debugging routing |
| Parent validation | Debug | Diagnostic during development |
| Infrastructure setup (TTL, PITR, streams) | Info | Useful confirmation during deploys |
| SNS/SQS subscription creation | Info | Important for verifying wiring |
| Resource discovery errors | Error | Actionable problems |
| Schema stitching warnings | Warn | Potential configuration issues |
| Plugin extension wiring | Info | Cross-plugin communication visibility |
| Builder decode errors | Error | Bugs in serialization |
| Missing handler/resource | Error | Configuration problems |
| OutputLogger (debug tool) | Debug | Developer debugging only |

### Migration Order

1. Create `DeployLogger.res` in `reventless/reventless-core/src/util/`
2. Migrate Categories 1-2 (handler registration + infra setup) — highest value
3. Migrate Categories 3-4 (channel wiring + resource discovery) — medium value
4. Migrate remaining categories incrementally
5. In-memory platform (Category 8) — lowest priority, already has good prefixes

### Relationship to Effect Logging

Deploy-time logging and runtime Effect logging serve different execution contexts but should share
formatting conventions:

- **LogFormat.res** helpers should be usable from both deploy-time and runtime code
- **Component naming** should match between deploy and runtime logs (same `~component` values)
- **Level semantics** should be consistent (Error = actionable, Warn = potential issue, Info = operational, Debug = diagnostic)

The deploy logger is intentionally NOT Effect-based — deploy-time code has no fiber, no layer, no
services. Trying to force Effect into Pulumi's Output.apply callbacks would add complexity for no
benefit. The two loggers serve different phases of the application lifecycle and should remain separate.

---

## Builder Decode Errors (Category 7) — Special Case

The builder decode errors (AutomationSlice, OutboundTranslationSlice, StateChangeSlice,
StateViewSlice) deserve special attention. These `Console.log2`/`Console.error` calls run inside
`Effect.sync`/`Stream.mapEffect` closures — they execute at Lambda runtime, not deploy time, even
though they're defined in builder files.

These should migrate to `Effect.logError` as part of Phase C (pure Effect callbacks), not as part
of deploy-time logging improvements. They were correctly identified as "deploy-time logging" in the
effect-logger plan because they're defined in `_Builder.res` files, but their execution context is
actually runtime.

---

## Summary

| Metric | Current | After Option B |
|--------|---------|----------------|
| Prefix styles | 5+ | 1 (`[deploy:{component}]`) |
| Level filtering | None | `DEPLOY_LOG_LEVEL` env var |
| Noisy handler registration | Always on | Debug (off by default) |
| Error visibility | Mixed with info | Clearly separated |
| Searchability | Ad-hoc grep | `grep "[deploy:"` or by component |
| Infrastructure change | None | 1 new ~20-line module |
