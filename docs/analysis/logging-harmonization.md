# Logging Harmonization Analysis

> **Status: Partial.** Basic Effect logging (`Effect.logInfo`/`logError`) and `LogFormat.res`
> formatters are in place. The full unified design below is not yet implemented.

**Created:** 2026-03-05 | **Updated:** 2026-03-29

---

## 1. Goals

1. **One mental model** — same logger type, same format, same level semantics for both deploy-time
   and runtime code.
2. **Concise output** — no redundant fields. CloudWatch Lambda integration already provides
   `timestamp`, `level`, and `requestId` — do not repeat them in the message body.
3. **Automatic location** — log origin should be identifiable without manually writing filenames or
   line numbers in every call.
4. **Formatting functions** — `fmtCmd`, `fmtEvent`, `fmtState` used everywhere; no ad-hoc
   string interpolation of command/event payloads.
5. **Easy level filtering** — `LOG_LEVEL` env var works across both contexts; `debug` is truly
   silent by default.
6. **Framework logs are sufficient** — application code should rarely need to add logs; the
   framework's own logging at key lifecycle points covers the common debugging scenarios.

---

## 2. Current State

### 2.1 Runtime Logging (`Effect.logInfo/logError`)

**What's in place:** Callbacks use `Effect.logInfo`/`Effect.logWarning`/`Effect.logError` injected
at dispatch points. `LogFormat.res` provides `commandJsonToLogMessage`,
`commandJsonsToLogMessages`, `event'JsonToLogMessage`.

**Problems:**
- `Effect.log*` takes a plain `string` — no structured data, no component name, no location.
- The same message appears identically in CloudWatch's `message` field and in the surrounding
  Lambda JSON envelope's `level`/`timestamp`. CloudWatch Insights queries can filter by level via
  the envelope, but structured queries on `component` or `correlationId` are impossible.
- `LogFormat` helpers are only used in `Aggregate_Callback.res`. Other callbacks interpolate
  commands and events ad-hoc.
- No `correlationId` in any log message.

### 2.2 Deploy-Time Logging (`Console.*` in `Output.apply`)

**What's in place:** Handler registration lines with `*****` prefix in
`AggregateRuntime_Builder_Common.res` and `EventCollectorRuntime_Builder_Single.res`.
Infrastructure setup messages in `Util_DynamoDb.res`, `EventCollectorChannel_Helpers.res`, etc.

**Problems:**
- Five incompatible prefix conventions: `*****`, `-----`, `[Module]`, `${__MODULE__}:`, none.
- All calls use `Console.log` regardless of severity — errors mixed with debug output.
- `Console.log2/3/4` passes multiple args; CloudWatch concatenates them into a single unstructured
  string or drops later args.
- No level filtering — verbose handler registration fires unconditionally.
- No component context on most messages.

### 2.3 Chatty / Redundant Logs — Reduce or Move to `debug`

| Location | Issue |
|----------|-------|
| `AggregateRuntime_Builder_Common.res` `*****` lines | Fire for every registered handler. A 10-plugin deploy generates 100+ lines. Should be `debug`. |
| `EventCollectorRuntime_Builder_Single.res:149` `*****` line | Duplicate of the same registration pattern. Also `debug`. |
| `EventCollectorRuntime_Builder_Single.res:75` `validateParent` | Diagnostic only; `debug`. |
| `Projection.res` `logAction` × 14 | Logs before AND inside `applyChanges`. Single `info` summary per batch is enough. |
| `CommandPublisher.res` × 9 | Logs buffer state at entry, each chunk, and exit. Move chunk-level detail to `debug`; keep one `info` on completion. |
| `GraphQL_SchemaInspector.res` × 13 | Full SDL dump on every startup. Move to `debug`. |
| `PluginConnectExtension_Builder.res` × 6 | Cross-plugin wiring detail; `debug`. |
| `Adapter.res:63` `resource: {resolved}` | Single `debug` line; already labelled debug — confirm it is truly suppressed. |

### 2.4 Missing Logs at Neuralgic Points — Add at `info`/`warn`/`error`

| Location | What's missing |
|----------|----------------|
| `StateViewSlice_Callback.res` | **Zero logs.** Silent projection failures. Add: events received count, projection result, decode errors. |
| `Heartbeat_Callback.res` | **Zero logs.** No operational visibility. Add: heartbeat published, extension point name, timeout. |
| `Aggregate_Callback.res` | EventLog replay count — currently only logs "finished", not how many events were replayed. |
| `ReadModel_Callback.res` | Only 1 log. Add: event count, projection action count, update success/failure. |
| `Plugin_Helpers.res` errors | Logs "Couldn't find Plugin" but not what was available. Add the set of known plugin names. |
| `AggregateRuntime` handler-not-found | Logs `no handler found: ${urn}` but not the available handlers — makes misconfiguration hard to diagnose. |

---

## 3. Unified Logger Design

### 3.1 One Logger Type for Both Contexts

Both runtime and deploy-time code will use the same record type:

```rescript
// reventless-core/src/util/Logger.res
type logFn = (~comp: string=?, ~data: JSON.t=?, string) => unit

type t = {
  debug: logFn,
  info:  logFn,
  warn:  logFn,
  error: logFn,
}
```

- **`~comp`** — component identifier, e.g. `"Aggregate(OrderItem)"` or `"AggregateRuntime"`.
  Optional so non-component code (utilities, builders) can omit it.
- **`~data`** — structured payload (command, event, error). Optional.
- **No `~loc` parameter.** See §3.2 for how location is handled.
- **`unit` return** — synchronous everywhere. Runtime callers in Effect context use a thin wrapper
  (see §3.3); deploy-time callers call directly.

### 3.2 Automatic Location via `__MODULE__`

ReScript's `__MODULE__` macro expands at compile time to the module name, e.g.
`"Aggregate_Callback"`. This maps 1:1 to the source file. No regex parsing, no optional parameter,
no per-call overhead.

**Convention:** pass `__MODULE__` as the `~comp` prefix when no named component is available,
or embed it in the component string:

```rescript
// At module top — zero cost, evaluated once:
let tag = __MODULE__  // "AggregateRuntime_Builder_Common"

// In a log call:
log.debug(~comp=tag, `forCommandTopic ${name}: set handler for ${urn}`)
```

For callbacks where the component name is dynamic:

```rescript
// In Aggregate_Callback.res (inside the Make functor):
let comp = `Aggregate(${Spec.name})`
log.info(~comp, ~data=fmtCmd(msg), "handling command")
```

`__LINE__` is not required in every call — the module name + message content is sufficient to
locate the source. Reserve `__LOC__` for temporary debugging only.

### 3.3 Format: Concise, No Redundant Fields

**CloudWatch Lambda structured logging** (Node 18+) already emits:
```json
{
  "timestamp": "...",
  "level": "INFO",
  "requestId": "...",
  "message": "<our content here>"
}
```

Our content should contain **only what CloudWatch doesn't already provide**:

```
Aggregate(OrderItem) cmd=CreateItem id=order-1 events=1 cid=abc-123
Aggregate(OrderItem) conflict retry=1/3
StateChangeSlice(OrderSlice) events=3 actions=2
AggregateRuntime no handler urn=arn:aws:sqs:…:OrderCmdTopic available=[OrderCmdTopic,ItemCmdTopic]
```

Format rules:
- Component name first (no field label needed — always the first token).
- Free-form message after component.
- Key facts as `key=value` pairs inline; no nested JSON objects.
- `cid=` for correlationId when available.
- Use `console.error`/`console.warn`/`console.log` to set the CloudWatch log level — **do not
  put `"level":"info"` in the message body**.

**Local / in-memory format** can be identical — it's readable as-is in a terminal. A colored
variant is optional (use `[DEBUG]`, `[INFO]`, `[WARN]`, `[ERROR]` prefixes for grep-ability).

### 3.4 Level Filtering

```rescript
// Logger.res
type level = Debug | Info | Warn | Error

let levelToInt = l => switch l { | Debug => 0 | Info => 1 | Warn => 2 | Error => 3 }

let makeLogger = (~minLevel=Info): t => {
  let shouldLog = l => levelToInt(l) >= levelToInt(minLevel)
  let emit = (level, ~comp=?, ~data=?, msg) =>
    if shouldLog(level) {
      let body = [
        comp->Option.getOr(""),
        msg,
        data->Option.map(d => d->JSON.stringifyAny->Option.getOr(""))->Option.getOr(""),
      ]->Array.filter(s => s != "")->Array.join(" ")
      switch level {
      | Error => Console.error(body)
      | Warn  => Console.warn(body)
      | _     => Console.log(body)
      }
    }
  { debug: emit(Debug, ...), info: emit(Info, ...), warn: emit(Warn, ...), error: emit(Error, ...) }
}

let silent: t = { debug: (_, ~comp=?, ~data=?, _) => (), ... }

// Read from env at startup — works for both Lambda and pulumi up:
let fromEnv = (): t =>
  makeLogger(~minLevel=switch Env.get("LOG_LEVEL") {
    | Some("debug") => Debug
    | Some("warn")  => Warn
    | Some("error") => Error
    | _             => Info
  })
```

**One env var — `LOG_LEVEL`** — controls both deploy-time and runtime verbosity. Set via:
- Lambda environment configuration in Pulumi (runtime)
- Shell environment during `pulumi up` (deploy-time)
- `process.env.LOG_LEVEL = "debug"` in tests that need verbose output

### 3.5 Runtime Integration (Effect)

The runtime Effect pipeline receives the logger via a thin adapter so callbacks don't import
`Logger.res` directly and Effect's own `logInfo` is replaced:

```rescript
// EffectLogger.res — thin wrapper that runs the logFn inside Effect
let logInfo  = (~comp=?, ~data=?, msg) => Effect.sync(() => _logger.contents.info(~comp?, ~data?, msg))
let logWarn  = (~comp=?, ~data=?, msg) => Effect.sync(() => _logger.contents.warn(~comp?, ~data?, msg))
let logError = (~comp=?, ~data=?, msg) => Effect.sync(() => _logger.contents.error(~comp?, ~data?, msg))
let logDebug = (~comp=?, ~data=?, msg) => Effect.sync(() => _logger.contents.debug(~comp?, ~data?, msg))
```

The logger instance is set once at platform startup:
```rescript
// RuntimeEnvironment_Lambda.res / RuntimeEnvironment_InMemory.res
EffectLogger.setLogger(Logger.fromEnv())
```

`correlationId` is embedded at dispatch time by creating a child logger:
```rescript
let makeChildLogger = (~cid: string, base: Logger.t): Logger.t => {
  let wrap = fn => (~comp=?, ~data=?, msg) => fn(~comp?, ~data?, msg ++ ` cid=${cid}`)
  { debug: wrap(base.debug), info: wrap(base.info), warn: wrap(base.warn), error: wrap(base.error) }
}
// At dispatch: EffectLogger.setLogger(makeChildLogger(~cid=correlationId, Logger.fromEnv()))
```

### 3.6 Deploy-Time Integration

Deploy-time code (`Output.apply` callbacks, builders) calls `Logger.t` directly — no Effect:

```rescript
// AggregateRuntime_Builder_Common.res
let log = Logger.fromEnv()  // called once at module load

// Inside Output.apply:
log.debug(~comp="AggregateRuntime", `forCommandTopic ${name}: set handler for ${urn}`)
log.info(~comp="AggregateRuntime", `registered CommandTopic handler name=${name}`)
```

No separate `DeployLogger` module needed — `Logger.res` serves both contexts.

---

## 4. Formatting Functions

Replace ad-hoc string interpolation with these helpers in `LogFormat.res`:

```rescript
// LogFormat.res — concise formatters, return inline key=value strings

// Command: "cmd=CreateItem id=order-1"
let fmtCmd = (msg: Message.commandJson): string =>
  `cmd=${msg.commandJson->JSON.Decode.object
    ->Option.flatMap(d => d->Dict.get("TAG"))
    ->Option.flatMap(JSON.Decode.string)
    ->Option.getOr("?")} id=${msg.id}`

// Event: "event=OrderPlaced id=order-1"
let fmtEvent = (msg: Message.event'<string, JSON.t>): string =>
  `event=${msg.event} id=${msg.id}`

// Event JSON (when only raw JSON available): "event=OrderPlaced id=order-1"
let fmtEventJson = (j: JSON.t): string =>
  // parse TAG + id from raw event JSON
  ...

// State summary: "state=Order(order-1) seq=42"
let fmtState = (~name: string, ~id: string, ~seq: int): string =>
  `state=${name}(${id}) seq=${seq}`

// Batch: "cmds=3 [CreateItem,UpdateItem,DeleteItem]"
let fmtCmds = (msgs: array<Message.commandJson>): string =>
  `cmds=${msgs->Array.length->Int.toString} [${
    msgs->Array.map(fmtCmd)->Array.join(",")}]`

// Error: "err=<message>"
let fmtExn = (e: exn): string =>
  `err=${e->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")}`
```

**Usage pattern across callbacks:**

```rescript
// Aggregate_Callback.res
log.info(~comp, ~data=None, `handling ${fmtCmds(msgs)}`)
log.info(~comp, `${fmtState(~name=Spec.name, ~id, ~seq)} replay done events=${n->Int.toString}`)
log.info(~comp, `${fmtCmd(msg)} → ${eventCount->Int.toString} event(s)`)
log.warn(~comp, `${fmtState(...)} conflict retry=${retry->Int.toString}/${max->Int.toString}`)

// StateViewSlice_Callback.res
log.info(~comp, `events=${rawEvents->Array.length->Int.toString} decoded=${events->Array.length->Int.toString} actions=${actions->Array.length->Int.toString}`)

// Heartbeat_Callback.res
log.info(~comp, `heartbeat ep=${Spec.extensionPointName} timeout=${Spec.timeout->Int.toString}s`)
```

---

## 5. What Framework Logs Should Cover

Application code should not need to add logs for common debugging. The framework must log at these
points so issues are diagnosable without application-level logging:

| Lifecycle point | Level | Key fields |
|-----------------|-------|-----------|
| Command received by aggregate | `info` | component, cmd, id |
| Events generated by behavior | `info` | component, id, event names, count |
| No events generated (duplicate / already done) | `info` | component, id, cmd |
| EventLog replay completed | `info` | component, id, events replayed |
| Conflict detected → retry | `warn` | component, id, retry count |
| Conflict retries exhausted | `error` | component, id |
| Behavior error | `error` | component, id, error |
| Event collected by read model / slice | `info` | component, event, id |
| Projection actions applied | `info` | component, action count |
| Projection decode failure | `warn` | component, event type, error |
| Heartbeat published | `info` | component, extension point, timeout |
| Handler registration (during deploy) | `debug` | component, urn |
| No handler found at dispatch | `warn` | urn, available urns |
| Resource resolution error (deploy) | `error` | component, resource name |
| CommandPublisher batch sent | `info` | cmd count, size |
| CommandPublisher error | `error` | error, cmd count |

---

## 6. Migration Plan

### Phase 1 — Logger module + format (prerequisite)

1. Create/replace `reventless-core/src/util/Logger.res` with the unified `makeLogger` / `fromEnv` /
   `makeChildLogger` / `silent` implementation.
2. Update `LogFormat.res` with `fmtCmd`, `fmtEvent`, `fmtEventJson`, `fmtState`, `fmtCmds`,
   `fmtExn` helpers.
3. Wire `EffectLogger` to use `Logger.t` — `EffectLogger.setLogger(Logger.fromEnv())` at
   both Lambda and InMemory platform startup.

### Phase 2 — Reduce chatty logs

Move the following to `debug` level (or remove if redundant):

- `AggregateRuntime_Builder_Common.res` `*****` handler registration lines (3 calls).
- `EventCollectorRuntime_Builder_Single.res:149` `*****` line + `:75` validateParent line.
- `Projection.res` `logAction` — replace 14 individual action logs with one `info` summary
  per `handleActions` call: `comp=${…} actions=${n}`.
- `CommandPublisher.res` — keep one `info` on completion; move per-chunk logs to `debug`.
- `GraphQL_SchemaInspector.res` schema dump — `debug`.
- `PluginConnectExtension_Builder.res` × 6 — `debug`.

### Phase 3 — Add missing logs

- `StateViewSlice_Callback.res`: add `info` for events received / decoded / actions; `warn` for
  decode failures.
- `Heartbeat_Callback.res`: add `info` on publication.
- `Aggregate_Callback.res`: add replay event count to the "finished" log.
- `ReadModel_Callback.res`: add event + action counts.
- `AggregateRuntime` no-handler warn: include list of available handler URNs.

### Phase 4 — Standardize remaining Console calls

Apply `Logger.t` (replacing raw `Console.*`) to:

- `Util_DynamoDb.res`, `Util_DynamoDbStream.res`, `Util_SNS.res`, `Util_SNS_FIFO.res` — infra
  setup; use `log.info`/`log.error`.
- `EventCollectorChannel_Helpers.res` — subscription wiring; `info`.
- `Plugin_Helpers.res` error paths — `error` with available plugins list.
- `EventTopic.res`, `Adapter.res` — `info`/`debug`.

In-memory platform (`GraphQL_Server.res`, `MCP_Server.res`) keeps its existing `[GraphQL]`/`[MCP]`
prefixed `Console.log` calls — they are local-dev only and the current approach is fine.

### Phase 5 — Remove legacy code

- Remove the old `Logger.res` if a prior version existed with `Level`, `createTag`, `logCmdJson`,
  etc. — `LogFormat.res` replaces the formatting part; `Logger.res` is now the unified logger.
- Remove `OutputLogger.res` (deploy debug tool; leftover from development) or demote to test-only.
- Clean up commented-out `Console.log2` in `Mapper1toN.res`.

---

## 7. Summary of Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Logger type | Single `Logger.t` record for both contexts | No context switching mental overhead |
| Format | `comp msg key=val cid=…` (plain text, one line) | CloudWatch already wraps with timestamp/level/requestId; no duplication |
| Log level in message | **No** — use `console.error`/`console.warn`/`console.log` | CloudWatch envelope already has level; duplication wastes ingested bytes |
| Source location | `__MODULE__` as component prefix (automatic) | Compile-time, zero cost, no manual maintenance, maps directly to .res file |
| Line numbers | Only for temporary debugging (`__LOC__`) | Module name + message is sufficient for production diagnosis |
| Level control | `LOG_LEVEL` env var, single knob for both contexts | Standard Lambda / Node practice; no redeploy needed to change verbosity |
| correlationId | Append `cid=` suffix via child logger at dispatch time | Simpler than service lookup per log call; baked in for entire request |
| Formatting | `fmtCmd`, `fmtEvent`, `fmtState`, `fmtCmds`, `fmtExn` in `LogFormat.res` | Consistent format across all callbacks; no ad-hoc interpolation |
| Deploy-time | Same `Logger.t`, not Effect-based | Deploy code has no Effect pipeline; same type keeps the mental model uniform |
| MCP / GraphQL server | Keep existing prefixed `Console.log` | Local dev only, never in production Lambda |
| Application logs | Framework logs cover all neuralgic points | Application code should not need to add logs for common scenarios |
