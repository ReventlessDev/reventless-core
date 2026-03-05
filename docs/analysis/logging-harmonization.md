# Logging Harmonization Analysis

**Created:** 2026-03-05

**Context:** After `docs/plans/effect-logger-and-request-context.md` is implemented, all callback
logging will go through the Effect Logger service. This analysis examines the full logging landscape
and proposes a unified approach for structured, location-aware, level-controllable logging across
the entire framework.

---

## 1. Current State — Four Logging Mechanisms

The codebase currently uses four independent logging mechanisms with no shared structure:

### 1.1 `Logger.res` (reventless-core/src/util/)

Synchronous logging utility with level-based dispatch to Console methods.

**Features:**
- `__LOC__`-based source location via `createTag(~level, ~loc)` — regex-parses ReScript's
  `File "path.res", line N, characters X-Y` into `filename.res#N:`
- Four levels: `Debug | Info | Warning | Error | Custom(string)`
- Structured formatting helpers: `commandJsonToLogMessage`, `event'JsonToLogMessage`,
  `commandJsonsToLogMessages`
- `Debug` level is a **noop** (line 73) — disabled for CloudWatch cost control

**Problems:**
- `__LOC__` is passed as `~loc=?` (optional) — many call sites omit it, producing empty tags
- Log output format is `(tag, description, item)` via `Console.info3` — three separate arguments,
  not a single structured string. CloudWatch and other log aggregators treat each arg as separate
  metadata
- The `createTag` regex has a bug: it captures `captures[0]` (the full match) and `captures[1]`
  (the first group), but should use `captures[1]` (filename) and `captures[2]` (line). The current
  output includes the full match string instead of just the filename
- `Debug` being a noop means debug logging is an all-or-nothing compile-time decision — no runtime
  level switching
- `~map` parameter is rarely used and adds complexity
- `~stringify` parameter inconsistently applied

**Usage:** ~50 call sites across callbacks, operations, utilities, and AWS adapters.

### 1.2 Direct `Console.log`/`Console.log2`/`Console.log3`

Raw console output with ad-hoc formatting.

**Locations (by category):**

| Category | Files | Count |
|----------|-------|-------|
| Component callbacks | SideEffectHandler, EventMapper, Counter, ReadModel, CommandGenerator, Plugin | ~25 |
| Infra mapping types | ExtensionPointMapping, ExtensionMapping | ~15 |
| MCP server | MCP_Server.res | ~15 |
| Projection | Projection.res | ~5 |
| Test files | BehaviorTest, ProjectionTest | ~3 |
| Examples | DebugSchema.res | ~4 |

**Problems:**
- No level indication — everything goes to `console.log` (INFO in CloudWatch)
- No source location
- No structured format — impossible to filter or parse
- Mixed concerns: diagnostic logging (should be debug) alongside error reporting

### 1.3 `EffectLogger` (rescript-effect/src/)

Effect service wrapping Console methods. Currently provided at three dispatch points
(`Runtime.runEffectHandler`, `AggregateRuntime_Builder_Common.runEffect`,
`EventCollectorRuntime_Builder_Single.runEffect`) — always hardcoded to `consoleLogger`.

**Type:**
```rescript
type t = {
  debug: string => Effect.t<unit, unit, unit>,
  info: string => Effect.t<unit, unit, unit>,
  warn: string => Effect.t<unit, unit, unit>,
  error: string => Effect.t<unit, unit, unit>,
}
```

**Problems:**
- Takes a single `string` — no structured data, no source location
- `consoleLogger` maps both `debug` and `info` to `Console.log` — no level distinction
- No level filtering — the `silent` implementation suppresses everything, but there's no way to
  show only errors or only info+errors
- After the effect-logger plan is implemented, all callbacks will use this — but without structural
  improvements, log output will be *worse* than Logger.res (losing `__LOC__` and formatting)

### 1.4 `runtimeLogger` (Runtime.res)

Synchronous `{info, warn}` record for builder-phase diagnostics. Used in `Output.apply` callbacks
at deploy time and in `aggregateHandler`/`eventCollectorHandler` at runtime.

**Usage:** ~12 call sites across `AggregateRuntime_Builder_Common.res` and
`EventCollectorRuntime_Builder_Single.res`.

**Problems:**
- No `error` or `debug` level
- No source location
- Not injectable at the platform level (hardcoded to `defaultLogger` or `silentLogger`)

---

## 2. Assessment of the `__LOC__` Approach

### What Works

- ReScript's `__LOC__` macro is zero-cost — it expands at compile time to a string literal
- When used consistently, it gives exact file+line for every log message
- The `filename.res#line:` format is compact and grep-friendly

### What Doesn't Work

1. **It's optional** — ~40% of `Logger.*` call sites omit `~loc=__LOC__`, producing empty tags
2. **Regex parsing is fragile** — the `createTag` function regex-parses the `__LOC__` string at
   runtime on every log call. This is unnecessary overhead and the current regex has an off-by-one
   in capture group indexing
3. **`__LOC__` expands to verbose strings** — `File "src/components/Aggregate/Aggregate_Callback.res", line 95, characters 14-73"` is long
   and wasteful if only filename+line are needed
4. **Not available in Effect Logger** — after migration, callbacks lose location info entirely
5. **`__MODULE__` is sometimes used instead** (e.g., `Counter_Callback.res:48`) — inconsistent

### Recommendation: Keep `__LOC__`, Make It Mandatory, Move Parsing to Compile Time

Rather than dropping `__LOC__`, make it a required parameter in the Effect Logger helper and
extract location info once at the call site rather than parsing it per-log-call.

---

## 3. Proposal: Unified Structured Logging

### 3.1 Structured Log Message Type

Define a single log entry structure used everywhere:

```rescript
// In rescript-effect/src/LogEntry.res (new file)
type t = {
  level: [#debug | #info | #warn | #error],
  loc: string,           // "Aggregate_Callback.res#95" — pre-formatted at call site
  component: string,     // "Aggregate", "ReadModel", "StateChangeSlice", etc.
  message: string,       // Human-readable description
  data: option<JSON.t>,  // Optional structured payload (command, event, error, etc.)
  correlationId: option<string>,  // From RequestContext when available
}
```

**Output format** (single JSON string per log call):
```json
{"level":"info","loc":"Aggregate_Callback.res#95","component":"Aggregate","msg":"Handling command","data":{"command":"CreateItem","id":"item-1"},"correlationId":"abc-123"}
```

This gives:
- **Filterability** — CloudWatch Insights can query by `level`, `component`, `correlationId`
- **Source tracing** — every log line says where it came from
- **Single string** — no multi-argument Console calls that scatter across CloudWatch fields

### 3.2 Enhanced Effect Logger Service

Replace the current `string => Effect.t<unit>` methods with a richer interface:

```rescript
// In rescript-effect/src/Logger.res (enhanced)
type logFn = (~loc: string=?, ~component: string=?, ~data: JSON.t=?, string) => Effect.t<unit, unit, unit>

type t = {
  debug: logFn,
  info: logFn,
  warn: logFn,
  error: logFn,
}
```

**Why `~loc` as an optional string parameter?**
- Call sites pass `~loc=__LOC__` — zero cost, exact location
- The Logger implementation parses it once and includes in output
- Call sites that can't provide `__LOC__` (e.g., dynamically generated) omit it — they still log, just without location

**Why `~component` as a parameter?**
- Callbacks are generated from functors with `Spec.name` — the component name is statically known
- Passing it explicitly is clearer than trying to extract it from `__LOC__` file paths
- Enables filtering by component type AND instance (e.g., `component: "StateChangeSlice(OrderSlice)"`)

### 3.3 Level Filtering via Configurable Implementation

Instead of the current binary consoleLogger/silent choice, provide a level-filtered logger:

```rescript
type level = Debug | Info | Warn | Error

// Numeric ordering for comparison
let levelToInt = level => switch level {
  | Debug => 0
  | Info => 1
  | Warn => 2
  | Error => 3
}

let makeLogger = (~minLevel: level=Info): t => {
  let shouldLog = level => levelToInt(level) >= levelToInt(minLevel)

  let emit = (level, ~loc=?, ~component=?, ~data=?, msg) => {
    Effect.sync(() => {
      if shouldLog(level) {
        let entry = {
          "level": switch level { | Debug => "debug" | Info => "info" | Warn => "warn" | Error => "error" },
          "loc": loc->Option.map(parseLoc)->Option.getOr(""),
          "component": component->Option.getOr(""),
          "msg": msg,
          "data": data->Option.getOr(Null.null->Obj.magic),
        }
        switch level {
        | Error => Console.error(entry->JSON.stringifyAny->Option.getOr(""))
        | Warn => Console.warn(entry->JSON.stringifyAny->Option.getOr(""))
        | _ => Console.log(entry->JSON.stringifyAny->Option.getOr(""))
        }
      }
    })
  }

  {
    debug: emit(Debug, ...),
    info: emit(Info, ...),
    warn: emit(Warn, ...),
    error: emit(Error, ...),
  }
}

let consoleLogger = makeLogger(~minLevel=Debug)
let productionLogger = makeLogger(~minLevel=Info)  // Skips debug
let silent = { debug: _ => Effect.succeed(()), info: _ => Effect.succeed(()), ... }
```

**Level switching at the platform level:**
```rescript
// In RuntimeEnvironment_Lambda.res or RuntimeEnvironment_InMemory.res:
let logLevel = switch Env.get("LOG_LEVEL") {
  | Some("debug") => Debug
  | Some("warn") => Warn
  | Some("error") => Error
  | _ => Info
}
let logger = Logger.makeLogger(~minLevel=logLevel)
```

This replaces the current `Debug => ()` noop in `Logger.res` with a runtime-configurable level
check. The `LOG_LEVEL` environment variable is standard practice for Lambda functions and can
be set per-environment in Pulumi configuration.

### 3.4 RequestContext Integration

After the effect-logger plan provides `RequestContext` at dispatch, the Logger can automatically
enrich log entries:

```rescript
// Logger-with-context: a helper that combines Logger + RequestContext
let logWithContext = (~loc=?, ~component=?, ~data=?, level, msg) =>
  Effect.serviceWithEffect(RequestContext.tag, ({correlationId}) =>
    Effect.serviceWithEffect(Logger.tag, logger => {
      let enrichedData = switch data {
        | Some(d) => Some(/* merge correlationId into data */)
        | None => Some({"correlationId": correlationId}->Obj.magic)
      }
      switch level {
        | #info => logger.info(~loc?, ~component?, ~data=?enrichedData, msg)
        | #error => logger.error(~loc?, ~component?, ~data=?enrichedData, msg)
        | ...
      }
    })
  )
```

Alternatively, the `makeLogger` factory can accept an optional `correlationId` parameter at
construction time (set once at dispatch), avoiding the need to access `RequestContext` on
every log call:

```rescript
let makeLogger = (~minLevel=Info, ~correlationId=?): t => {
  // correlationId is baked into every emit call
  ...
}
```

This is simpler — the dispatch point already has the correlationId and can create a logger
with it embedded. Then `provideService(Logger.tag, makeLogger(~minLevel, ~correlationId))`.

**Recommendation:** Embed `correlationId` at logger construction time. It's cleaner and avoids
double service lookups on every log call.

### 3.5 Convenience Helpers for Domain Formatting

Keep the formatting functions from `Logger.res` but decouple them from Console output:

```rescript
// In reventless-core/src/util/LogFormat.res (renamed from Logger.res)
let commandJsonToLogMessage: Message.commandJson => string = ...  // unchanged
let commandJsonsToLogMessages: array<Message.commandJson> => array<string> = ...
let event'JsonToLogMessage: JSON.t => string = ...

// New: convert to JSON.t for structured data field
let commandJsonToData: Message.commandJson => JSON.t = ({id, commandJson}) =>
  [("command", commandJson), ("id", id->JSON.Encode.string)]
  ->Dict.fromArray->JSON.Encode.object

let eventJsonToData: JSON.t => JSON.t = eventJson' =>
  eventJson'  // already JSON — pass through, or extract relevant fields
```

**Usage in callbacks (after migration):**
```rescript
// Before (current):
Logger.logJsonEvent(~loc=__LOC__, eventJson', "handling event")

// After (proposed):
->Effect.tap(_ =>
  Effect.serviceWithEffect(Logger.tag, logger =>
    logger.info(
      ~loc=__LOC__,
      ~component=`Plugin(${id})`,
      ~data=LogFormat.eventJsonToData(eventJson'),
      "handling event",
    )
  )
)
```

### 3.6 Deploy-Time Logging (runtimeLogger Replacement)

The `runtimeLogger` handles two contexts:
1. **`Output.apply` callbacks** — deploy-time registration messages ("set handler for ...")
2. **`aggregateHandler`/`eventCollectorHandler`** — runtime dispatch messages ("found handler for ...")

For (1), `Console.log` is appropriate — these fire during `pulumi up` only. Use a simple
`[deploy]` prefix for identification:

```rescript
Console.log(`[deploy] forCommandTopic ${name}: set handler for ${urn}`)
```

For (2), these run inside async handlers that already call `runEffect`. Convert to Effect Logger:

```rescript
// In aggregateHandler:
let handler = async (event, context) => {
  await Effect.serviceWithEffect(Logger.tag, logger =>
    logger.info(~component="AggregateRuntime", `found handler for CommandTopic ${urn}`)
  )
  ->Effect.flatMap(_ => actualHandler(event, context))
  ->runEffect
}
```

Or simpler — log before calling `runEffect`:

```rescript
log.info(...)  // stays as Console.log for the dispatch routing message
await handler(event, context)->runEffect  // handler's own logging uses Effect Logger
```

**Recommendation:** Keep synchronous `Console.log` for the handful of dispatch routing messages
in `aggregateHandler`/`eventCollectorHandler`. These are 6 messages total and don't benefit
from Effect wrapping. Remove `runtimeLogger` type entirely — replace with direct `Console.log`
calls with a `[dispatch]` prefix.

### 3.7 Non-Callback Logging (Infra, MCP, Projection)

Several modules outside the Effect pipeline use `Console.log` directly:

| Module | Context | Recommendation |
|--------|---------|----------------|
| `ExtensionPointMapping.res` | Mapping incoming/outgoing events | These run inside async handlers invoked by callbacks. After callback migration, wrap in Effect or keep as `Console.log` with structured prefix |
| `ExtensionMapping.res` | Same as above | Same recommendation |
| `MCP_Server.res` | Local dev server diagnostics | Keep as `Console.log` with `[MCP]` prefix (already done). MCP server is in-memory only, never runs in Lambda |
| `Projection.res` | Query DB operations | Wrap in Effect Logger — Projection runs inside ReadModel callback Effect pipeline |
| `GraphQL_Stitcher.res` | Schema stitching warnings | Deploy-time only — use `Console.warn` with `[schema]` prefix |

---

## 4. Migration Path

### Phase 0: Enhance Effect Logger (before callback migration)

1. Extend `Logger.t` type to accept `~loc`, `~component`, `~data` parameters
2. Add `makeLogger(~minLevel, ~correlationId=?)` factory
3. Add `parseLoc` helper that extracts `filename.res#line` from `__LOC__` string (move from
   `Logger.res` to `rescript-effect/src/Logger.res`)
4. Add JSON-structured output format

This must happen **before** Work Item 1 of the effect-logger plan, so that the callback migration
uses the enhanced logger from the start — avoiding a second pass to add structure.

### Phase 1: Callback Migration (aligns with effect-logger plan Work Item 1)

Migrate each callback using the enhanced logger with `~loc=__LOC__` and `~component=Spec.name`.
Follow the ordering in the effect-logger plan.

### Phase 2: RequestContext + correlationId (aligns with effect-logger plan Work Item 2)

At dispatch, create logger with embedded correlationId:
```rescript
let runEffect = (~correlationId=?, effect) =>
  effect
  ->Effect.provideService(Logger.tag, Logger.makeLogger(~minLevel, ~correlationId?))
  ->Effect.provideService(RequestContext.tag, {correlationId: correlationId->Option.getOr("unknown")})
  ->Effect.runPromise
```

### Phase 3: Remove Legacy Infrastructure (aligns with effect-logger plan Work Items 3-4)

1. Replace `runtimeLogger` with direct Console.log (deploy-time) and keep Effect Logger (runtime)
2. Rename `Logger.res` to `LogFormat.res`, keeping only formatting functions
3. Remove `Logger.Level`, `Logger.log`, `Logger.info`, `Logger.warn`, `Logger.error`, `Logger.debug`
4. Remove `Logger.logCmdJson`, `Logger.logCmdJsons`, `Logger.logJsonEvent`

### Phase 4: Remaining Console.log Cleanup

Convert remaining `Console.log` calls in infra mappings and Projection to Effect Logger where
they run inside Effect pipelines, or to prefixed `Console.log` where they don't.

---

## 5. Summary of Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Log format | Single JSON string per entry | CloudWatch Insights queryable, parseable by any log tool |
| Source location | `__LOC__` (mandatory in callbacks) | Zero-cost compile-time expansion, exact file+line |
| Component identification | Explicit `~component` parameter | Clearer than inferring from file path, supports instance names |
| Level control | `LOG_LEVEL` env var + `makeLogger(~minLevel)` | Standard Lambda practice, runtime-switchable without redeploy (via Lambda env config) |
| correlationId | Embedded at logger construction time | Avoids double service lookup per log call |
| Deploy-time logging | Direct `Console.log` with `[deploy]` prefix | No Effect pipeline available, simple diagnostic messages |
| Runtime dispatch logging | Direct `Console.log` with `[dispatch]` prefix | Only ~6 messages, not worth Effect wrapping |
| Domain formatting | `LogFormat` module (renamed from Logger) | Keep formatting helpers, decouple from Console output |
| MCP server logging | Keep `[MCP]` prefixed Console.log | Local dev only, never in production Lambda |

---

## 6. Expected Outcome

After full implementation:

1. **Every log message** from callbacks includes: level, source location, component name,
   correlationId, and structured data — as a single JSON string
2. **One knob** (`LOG_LEVEL` environment variable) controls what gets logged across the
   entire system
3. **CloudWatch Insights queries** like `filter component = "Aggregate" and level = "error"`
   or `filter correlationId = "abc-123"` work across all log entries
4. **No more silent debug** — debug logging works when `LOG_LEVEL=debug`, hidden otherwise
5. **Test logging** uses `Logger.silent` — no console noise in test output
6. **Zero `Console.log` in production callback code** — all logging through Effect Logger service
