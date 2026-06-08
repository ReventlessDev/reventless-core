# Logging output optimization — clean JSON for cloud sinks, unchanged TTY

Scope: make Reventless logs render as clean, structured JSON in every
non-TTY sink (CloudWatch first, but the same shape works for Azure
Monitor, GCP Cloud Logging, Datadog, Loki) while preserving the current
human-readable terminal rendering on the local platform.

Status: **All three tiers implemented and locally verified** (full build clean;
407 reventless-core + 446 reventless-local tests green, incl. JSON-sink,
plugin/comp-field, detail-via-annotation, correlationId-surfacing, time/service,
and detail-truncation guards). Remaining before this plan can move to `done/`:
manual CloudWatch verification in alpha (§1.5, §2.5, §3.5) and — optional — the
broader Console cleanup (§2.6, see Tier 2 note).
Companion analysis: `docs/analysis/logging-output-optimization.md`.

## Problem (one-paragraph recap)

`Logger.emit` (`reventless/reventless-core/src/util/Logger.res:76-108`) is
already sink-aware — Lambda branch emits `{level, message, detail?}` JSON,
terminal branch emits coloured text. But three helpers pre-format ANSI
codes into the message **before** it reaches `emit`, so the JSON branch
embeds raw `\x1b[…m` escapes in the `message` field. About 30 stray
`Console.log/.warn/.error` calls in `reventless-aws/src/` bypass
`Logger.emit` entirely. The Lambda detection (`AWS_LAMBDA_FUNCTION_NAME`)
also misses Fargate, ECS, Azure, GCP, and CI runners. See the analysis
for the full trace.

## Related sink — the VS Code local platform runner

The Phase 9 runner ([reventless-vscode-local-platform-runner.md](./reventless-vscode-local-platform-runner.md))
spawns the app's local platform as a **non-TTY child** and forwards its stdout to the "Reventless — Platform"
view (as `platformLog` NDJSON events). Because `AnsiStyle.bold` / `LogPrefix.fmtComp` bake ANSI **before** sink
detection (the exact Tier 1.2/1.3 bug), the child emits coloured/bold logs despite being non-TTY.

- **Resolution (shipped):** rather than fight the ANSI, the runner **embraces** it — the `platformLog` wire
  payload keeps its ANSI ([`PlatformRunner.res`](../../reventless/reventless-gwt/src/PlatformRunner.res) no
  longer strips), and the extension renders it in a **VS Code Pseudoterminal** (an xterm renderer that
  interprets colour/bold), so the runner log reads exactly as on the command line. (An OutputChannel can't
  render ANSI — that's why the first attempt stripped it; the terminal is the right surface.)
- **Still relevant to Tier 1:** this only works because the *consumer* is a terminal. **Non-terminal** sinks
  (CloudWatch, a log file, `tee`) still want ANSI-free text, and the framework's pre-sink ANSI baking remains
  the Tier 1.2/1.3 fix below. Note the gap: the proposed detection has no "plain text, no ANSI" mode
  (`=text` keeps ANSI, `=json` emits JSON) — a piped text consumer wants neither; consider a third mode or
  defaulting non-TTY text to ANSI-off.

## Plan structure

Three tiers, each independently shippable:

- **Tier 1**: stop the bleeding — mechanical, behaviour-preserving for TTY.
- **Tier 2**: first-class structured fields — plugin/comp/correlationId.
- **Tier 3**: operational hygiene — truncation, ISO time, sample queries.

Open and merge Tier 1 first; verify CloudWatch is clean; then proceed.

---

## Tier 1 — Sink-aware formatting (single PR)

Goal: every JSON record's `message` field is free of `\x1b` escapes;
no observable change in TTY output.

> **DONE (code).** Single source of truth chosen (the note under §1.2): the
> resolver lives in `reventless-spec/src/AnsiStyle.res` (the lowest layer —
> `LogPrefix` depends on it, not vice versa), exposed as `isJsonSink()` /
> `useAnsi()` / `bold` / a test-only `reload()`. `LogPrefix.fmtComp` and
> `Logger.emit` both read it; the `_isLambda` external is gone. Detection
> matches the plan's table: `REVENTLESS_LOG_FORMAT` override wins, else TTY ⇒
> text, else JSON. Jest is non-TTY ⇒ defaults to JSON, so `LogFormatTest`
> forces `REVENTLESS_LOG_FORMAT=text` at file top for the existing
> human-format assertions; the new `describe("JSON sink")` flips to json.
> Open gate: deploy + CloudWatch eyeball (§1.5).

### 1.1 Centralise sink detection

**File**: `reventless/reventless-core/src/util/Logger.res`

Replace the `_isLambda` check with a single module-level binding
evaluated once at startup:

```rescript
@val external _isTty: option<bool> = "process.stdout.isTTY"
@val external _logFormat: option<string> = "process.env.REVENTLESS_LOG_FORMAT"

// "json" | "text" — resolved once.
let sinkFormat: string = switch (_logFormat, _isTty) {
| (Some("json"), _) => "json"
| (Some("text"), _) => "text"
| (_, Some(true)) => "text"
| _ => "json"
}

let isJsonSink = sinkFormat == "json"
```

Use `isJsonSink` everywhere instead of `isLambda`. Lambda, Fargate, ECS,
Azure Functions, GCP Cloud Run, Docker, CI runners all default to JSON;
local terminal stays text; explicit override always wins.

Drop the `_isLambda` external and the `isLambda` local in `emit`.

### 1.2 Make `AnsiStyle.bold` sink-aware

**File**: `reventless/reventless-spec/src/AnsiStyle.res`

Today (line 7): `let bold = s => \x1b[1m${s}\x1b[0m`. Read the same
`process.stdout.isTTY` / `REVENTLESS_LOG_FORMAT` once at module init and
make `bold` a no-op in JSON mode:

```rescript
@val external _isTty: option<bool> = "process.stdout.isTTY"
@val external _logFormat: option<string> = "process.env.REVENTLESS_LOG_FORMAT"

let _useAnsi = switch (_logFormat, _isTty) {
| (Some("json"), _) => false
| (Some("text"), _) => true
| (_, Some(true)) => true
| _ => false
}

let bold = s => _useAnsi ? `\x1b[1m${s}\x1b[0m` : s
```

`reventless-spec` is the lowest layer that can host this; both
`reventless-core/LogFormat` (which re-exports `bold`) and
`reventless-infra/ExtensionMapping`/`ExtensionPointMapping` (which call
`AnsiStyle.bold` directly) inherit the fix.

> Note: keep the two detection blocks (Logger and AnsiStyle) in sync.
> If we want a single source of truth, move the resolver into
> `reventless-spec/src/LogPrefix.res` (which both packages depend on)
> and re-export from `Logger`. Decide while implementing — either is
> fine, the duplication is < 8 lines.

### 1.3 Fix `LogPrefix.fmtComp` and friends

**File**: `reventless/reventless-spec/src/LogPrefix.res`

Today:
- `fmtComp` (line 150) always emits coloured + bold prefix.
- `fmtPlainPrefix` (line 135) always emits no-colour, no-bold prefix.
- `Logger.emit` picks `fmtPlainPrefix` in Lambda, `fmtComp` in TTY.
- `EffectLogger.withComp` (`reventless-core/src/util/EffectLogger.res:118-121`)
  always picks `fmtComp` — this is the main leak.

Fix: make `fmtComp` itself sink-aware (read the same `_useAnsi` flag and
fall back to `fmtPlainPrefix`'s body). Then `Logger.emit` no longer
needs the explicit branch, and `EffectLogger.withComp` becomes correct
without changes.

Keep `fmtPlainPrefix` exported for direct callers that always want
plain output regardless of sink (none today, but cheap to keep).

### 1.4 Regression test

**File**: `reventless/reventless-core/tests/logger/LogFormatTest.res`

Add a `describe("JSON sink", ...)` block that:

1. Sets `process.env.REVENTLESS_LOG_FORMAT = "json"` (or stubs
   `process.stdout.isTTY = false`) — requires resetting the cached
   `_useAnsi` / `isJsonSink` for the duration of the test. Easiest path:
   expose a test-only `Logger._reload()` that re-evaluates the env, or
   inject a config record instead of caching at module init.
2. Captures `Console.log` output (already done in existing tests via
   `Jest.mock` or a `Console.log` spy).
3. Asserts every captured line:
   - Parses as JSON without error.
   - Contains no `\x1b` (ANSI ESC) characters anywhere.
   - Has `level` ∈ {"DEBUG","INFO","WARN","ERROR"}, `message` is a string.

Cover at least: `Logger.info`, `Logger.warn`, `EffectLogger.logInfo`,
and one call through `LogFormat.cmdName` / `LogFormat.eventName`.

### 1.5 Acceptance

- Existing `LogFormatTest` passes unchanged (TTY behaviour preserved).
- New JSON-sink tests pass.
- Manual check: deploy a single Lambda function (e.g. the example
  online-shop catalog command Lambda) on `alpha`, trigger one command,
  inspect the CloudWatch log group — every line is JSON, every
  `message` field is plain text, no `\x1b` sequences anywhere.
- `pnpm run build 2>&1 | grep -E "Warning|warning|error|Error"`: clean.

### 1.6 Files touched (Tier 1)

```
reventless/reventless-spec/src/AnsiStyle.res         (~10 lines)
reventless/reventless-spec/src/LogPrefix.res         (~15 lines)
reventless/reventless-core/src/util/Logger.res       (~20 lines)
reventless/reventless-core/tests/logger/LogFormatTest.res (~80 lines added)
```

No other call site touched. PR diff < 150 lines.

---

## Tier 2 — First-class structured fields

Goal: promote what's currently baked into `message` into queryable
top-level JSON keys; route stray `Console.*` through `Logger.emit`.

> **DONE (code), pending CloudWatch verification.**
> - **2.1** `Logger.emit` JSON branch now emits `plugin`/`comp` as top-level
>   keys; `message` is clean. Tests in `LogFormatTest` ("JSON sink").
> - **2.2** `Effect.annotateLogs` binding added to `rescript-effect`.
>   `runEffect` in `AggregateRuntime_Builder_Common` + `EventCollectorRuntime_Builder_Single`
>   annotate `correlationId`. All 10 AWS Lambda entry-point shims
>   (`*EntryPoint.mjs`) annotate `correlationId` **and** `requestId`
>   (captured from `context.awsRequestId` at handler entry into a
>   module-level `_currentRequestId`, read by their `runEffect` — chosen over
>   a signature change to avoid call-site churn on unverifiable runtime shims).
>   `EffectLogger.install()` decodes `loggerOptions.annotations`
>   (`HashMap.toEntries`): `comp`/`detail` get dedicated emit handling, the
>   rest (correlationId/requestId) pass through `Logger.emit(~annotations)` as
>   top-level string fields. Locally unit-tested; **end-to-end correlation
>   trace (§2.5) still needs an alpha deploy.**
> - **2.3** `\x00` detail-encoding removed. `EffectLogger` now carries
>   `~comp`/`~detail` as Effect log annotations (detail JSON-stringified, re-parsed
>   in `install()`); `Logger.detailSeparator` deleted.
> - **2.4** Console cleanup done for the **6 named files** (~28 sites:
>   `Platform.res`, `Plugin_Stack.res`, `Util_StaticBundle.res`,
>   `Util_AppSync_Caller.res`, `ClonerRunner_Fargate_Runtime.res`,
>   `StateViewSliceRuntime_Builder_Single.res`). **Not done:** the broader
>   "0 hits across aws+core+infra" goal (§2.6) — ~50 further `Console.log2/3/4`
>   debug-trace sites (DataCleaner, Counter, Message, EventMapper_Builder,
>   GraphQL_Stitcher, …) remain; many are multi-arg and need per-site
>   judgement on `~data` shape. Tracked as follow-up.

### 2.1 Add `plugin` and `comp` as top-level JSON fields

**File**: `reventless/reventless-core/src/util/Logger.res`

In the JSON branch of `emit`, instead of:

```rescript
let message = `${fmtPlainPrefix(~comp?, ())}${msg}`
```

emit a structured object:

```rescript
let plugin = LogPrefix.resolvePlugin(~comp?, ())
let obj = Dict.fromArray([
  ("level", levelLabel(level)->JSON.Encode.string),
  ("message", msg->JSON.Encode.string),
  // optional fields:
  ...plugin->Option.mapOr([], p => [("plugin", JSON.Encode.string(p))]),
  ...comp->Option.mapOr([], c => [("comp", JSON.Encode.string(c))]),
  ...detail->Option.mapOr([], d => [("detail", d)]),
])
```

(Pseudo-code — adapt to ReScript's `dict` builder ergonomics.)

TTY branch is unchanged; `fmtComp` still renders `[Plugin][Comp]` for
humans.

CloudWatch Logs Insights now supports queries like:

```
fields @timestamp, plugin, comp, level, message
| filter level = "ERROR" and plugin = "Catalog"
| sort @timestamp desc
```

### 2.2 Carry `correlationId` and `requestId`

**Files**:
- `reventless/reventless-core/src/util/EffectLogger.res`
- `reventless/reventless-core/src/adapter/Runtime/AggregateRuntime_Builder_Common.res`
- `reventless/reventless-core/src/adapter/Runtime/EventCollectorRuntime_Builder_Single.res`
- (any other site that builds a `RequestContext`)

Effect's `Effect.annotateLogs` API attaches structured key/value pairs
to log records. Two steps:

1. **Annotate at the boundary.** Wherever a `RequestContext` is
   constructed (the two `*Runtime_Builder_*.res` files set
   `correlationId` from the incoming event), wrap the inner handler
   with `Effect.annotateLogs("correlationId", correlationId)`. The
   correlation id then attaches to every `Effect.logInfo` /
   `EffectLogger.logInfo` call inside the request scope automatically.

2. **Decode in `install()`.** `EffectLogger.install()` already
   intercepts `defaultLogger.log`; extend it to read
   `opts.annotations` (an Effect-internal map) and merge known
   fields into the JSON. Pass them through to `Logger.emit` as a
   new `~annotations: dict<string>` arg.

For Lambda `requestId`: in the Lambda handler shim
(`reventless/reventless-aws/src/adapter/Runtime/*EntryPoint.mjs`),
read `context.awsRequestId` and call
`Effect.annotateLogs("requestId", context.awsRequestId)` at the
outermost Effect wrap. Same mechanism, no new plumbing.

### 2.3 Drop the `\x00` detail encoding hack

**File**: `reventless/reventless-core/src/util/EffectLogger.res:54, 96-106`

Today `encode` smuggles `~detail` through Effect's stringly-typed log
payload by joining `message + "\x00" + JSON.stringify(detail)`, and
`install()` splits it back out. With annotations carrying structured
fields (2.2), detail becomes another annotation key.

Replace `encode` with annotation-based passing:

```rescript
let logInfo = (~comp=?, ~detail=?, msg) => {
  let withComp = msg => Logger.fmtPlainPrefix(~comp?, ()) ++ msg
  Effect.logInfo(withComp(msg))
  ->switch detail {
    | Some(d) => Effect.annotateLogs(_, "detail", d->JSON.stringify)
    | None => x => x
    }
  ->_withMinimumLogLevel(_effectMin())
}
```

Then `install()` reads `detail` off annotations and re-parses, or just
passes the already-stringified JSON through.

Delete `Logger.detailSeparator` after the migration.

### 2.4 Route stray `Console.*` through `Logger.emit`

About 30 sites; all in `reventless-aws/src/`. Add at the top of each
file:

```rescript
let log = Logger.fromEnv()
```

Then rewrite call by call:

| From | To |
|------|-----|
| `Console.log("[preResolversSchemaHook] Pushing schema for plugin ${name}@${version} to AppSync")` | `log.info(~comp="Platform:deploy", "Pushing schema for plugin ${name}@${version}")` |
| `Console.error("[Util_AppSync_Caller] query errors: …")` | `log.error(~comp="Util_AppSync_Caller", ~data=errors, "query errors")` |
| `Console.warn("Platform: heartbeat EP channel has no resources")` | `log.warn(~comp="Platform", "heartbeat EP channel has no resources")` |

File list (from the analysis):

- `reventless-aws/src/Plugin_Stack.res` (2 sites — CloudFront invalidation)
- `reventless-aws/src/Platform.res` (~20 sites — deploy hooks)
- `reventless-aws/src/util/Util_StaticBundle.res` (1 site)
- `reventless-aws/src/util/Util_AppSync_Caller.res` (2 sites)
- `reventless-aws/src/adapter/Cloner/ClonerRunner_Fargate_Runtime.res` (1 site)
- `reventless-aws/src/adapter/Runtime/StateViewSliceRuntime_Builder_Single.res` (2 sites)

Search command for completeness:

```bash
grep -rn "Console\.\(log\|warn\|error\)" --include="*.res" \
  reventless/reventless-aws/src reventless/reventless-core/src reventless/reventless-infra/src \
  | grep -v ".res.mjs"
```

Acceptance: 0 hits returned (modulo the in-place comment-out cases).

### 2.5 Acceptance

- CloudWatch records carry `plugin`, `comp`, `correlationId`, `requestId`
  as top-level fields (where applicable).
- A correlation-id trace across an end-to-end command flow
  (`CommandTopic` → `Aggregate` → `EventLog` → `ReadModel`) shows the
  same `correlationId` on every record.
- Insights query `filter plugin = "Catalog" and level = "ERROR"` returns
  results across all Lambda log groups.
- No `Console.log/.warn/.error` remains in `reventless-aws/src/`,
  `reventless-core/src/`, or `reventless-infra/src/`.

### 2.6 Suggested PR slicing

- PR A: structured `plugin`/`comp` fields (2.1) + matching tests.
- PR B: `correlationId`/`requestId` annotations (2.2) + drop `\x00` hack (2.3).
- PR C: Console cleanup (2.4) — touches the most files but mechanical.

---

## Tier 3 — Operational hygiene

Low priority, ship after Tier 2 lands.

> **DONE (code).**
> - **3.1** `Logger.truncateDetail` replaces a `~detail` larger than
>   `REVENTLESS_LOG_MAX_DETAIL_BYTES` (default 32 KB) with
>   `{truncated, bytes, preview}` (512-char preview).
> - **3.2** Every JSON record carries an RFC 3339 `time` field (`Logger.iso`).
> - **3.3** `service` field from `REVENTLESS_SERVICE` (override) else
>   `AWS_LAMBDA_FUNCTION_NAME`, read per-emit so a platform/test can set it.
> - **3.4** New guide: `docs/guides/cloudwatch-logs-insights.md` (field table +
>   6 ready-to-paste Insights queries).
> - Tests in `LogFormatTest` ("JSON sink"): time present + RFC 3339, service via
>   env, oversized-detail truncation. Remaining §3.5 gate: see the truncation /
>   field checks against a real CloudWatch record after deploy.

### 3.1 Truncate oversized `detail`

**File**: `reventless/reventless-core/src/util/Logger.res`

Before stringifying:

```rescript
let maxDetailBytes = 32 * 1024  // configurable via env var
let stringified = detail->JSON.stringify
let payload = stringified->String.length > maxDetailBytes
  ? Dict.fromArray([
      ("truncated", JSON.Encode.bool(true)),
      ("bytes", JSON.Encode.int(stringified->String.length)),
      ("preview", stringified->String.slice(~start=0, ~end=512)->JSON.Encode.string),
    ])->JSON.Encode.object
  : detail
```

Prevents silent drops on bulk-projection logs.

### 3.2 RFC 3339 timestamps in JSON

Today `hms()` produces `HH:MM:SS` for the TTY branch only. The JSON
branch has no `time` field — CloudWatch fills in its own ingest time,
but downstream tooling (Insights queries against exported S3 buckets,
Datadog re-ingestion) benefits from an embedded ISO timestamp.

Add `("time", Date.now()->Date.fromTime->Date.toISOString)` to the
JSON object.

### 3.3 `service` field

Derive from `process.env.AWS_LAMBDA_FUNCTION_NAME` (or the platform
namespace in non-Lambda environments) and inject at module init.
Makes cross-Lambda Insights queries trivial.

### 3.4 Companion docs guide

**File**: `docs/guides/cloudwatch-logs-insights.md` (new)

Short guide with 3-5 ready-to-paste Insights queries:

- All errors across all plugins, last 1h
- Command-handler latency by plugin (using `requestId` + `@timestamp`)
- Correlation-id timeline (paste an id, get every step)
- Top 10 slow read-model projections
- Plugin connect/disconnect events on the platform

These are the queries the team will actually run; the structured fields
only pay off when people know what to type.

### 3.5 Acceptance

- A `detail` payload > 32 KB lands in CloudWatch as `{truncated: true, bytes: N, preview: "…"}`.
- Every JSON record has a `time` field with RFC 3339 timestamp.
- `service` field present on Lambda records.
- New Insights guide committed under `docs/guides/`.

---

## Sequencing

1. **Tier 1** — single PR, blocker for everything downstream. Verify in
   alpha CloudWatch before proceeding.
2. **Tier 2 PR A** (structured fields).
3. **Tier 2 PR B** (correlation/request id) — depends on PR A.
4. **Tier 2 PR C** (Console cleanup) — independent of A/B, can run in
   parallel.
5. **Tier 3** — incremental, no fixed order.

Move this plan to `docs/plans/done/` when all three tiers are merged
and verified in alpha CloudWatch.
