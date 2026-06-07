# Logging output optimization — readable everywhere, processable in the cloud

## Goal

The local platform already produces excellent terminal logs:

```
12:43:11 I [Catalog][Aggregate(Product)] handling command 1/1: Add(p-1, {name:"Cat 1"})
12:43:11 I [Catalog][Aggregate(Product)] event 1/1: Added(p-1, {name:"Cat 1"})
```

In CloudWatch the same lines arrive as raw escape sequences:

```
{"level":"INFO","message":"[35m[1m[Catalog][0m[1m[Aggregate(Product)][0m handling command 1/1: [1mAdd[0m(p-1, {name:\"Cat 1\"})"}
```

Plus a parallel stream of unstructured `console.log` lines from deploy-time
hooks and runtime adapters that carry their own `[Bracket]` prefixes but no
JSON envelope at all.

We want the same human-readable rendering in a TTY and clean, structured,
queryable JSON in any non-TTY sink — CloudWatch first, but the same shape
also works for Azure Monitor, GCP Cloud Logging, Datadog, Loki, etc.

## How logging is wired today

### The unified core: `Logger.emit`

`reventless-core/src/util/Logger.res` defines a single `emit` function that
all logging is supposed to flow through. It already branches on environment:

```rescript
let emit = (~level, ~comp=?, ~detail=?, msg) => {
  let isLambda = _isLambda->Option.isSome
  if isLambda {
    // CloudWatch — JSON envelope
    Console.log({"level": …, "message": …, "detail": …}->JSON.stringify)
  } else {
    // Terminal — ANSI-coloured single line
    Console.log(`${hms()} ${cyan}I${reset} ${c}${msg}`)
  }
}
```

`Logger.t` (the record API used at the platform level) and `EffectLogger`
(used in Effect-based runtime code) both forward into `emit`. That part of
the design is correct: one decision point, one format per sink.

### Where ANSI codes leak into the JSON

Three independent leaks bypass the `isLambda` branch:

1. **`EffectLogger.withComp` (`reventless-core/src/util/EffectLogger.res:118-121`)**
   builds the `[Plugin][Comp]` prefix with `Logger.fmtComp` —
   the *coloured* variant — and embeds it into the message string
   **before** the message reaches `Logger.emit`. By the time `emit` checks
   `isLambda`, the prefix is already poisoned with `\x1b[…m` escapes.
   It then JSON-stringifies that poisoned string into `message`.

2. **`AnsiStyle.bold` (`reventless-spec/src/AnsiStyle.res:7`)** is an
   unconditional `s => \x1b[1m${s}\x1b[0m`. Every call site that wants to
   highlight a command/event name calls this directly — including
   `LogFormat.bold/cmdName/eventName/...` which re-export it — and the
   bold markers travel through every layer into the JSON `message`.
   Examples:
   - `ExtensionPointMapping.res:200`: `cmdJson->variantNameOfJson->AnsiStyle.bold`
   - `LogFormat.res:34-36, 102-103`: every `cmdName`/`eventName` is bold
   - `Aggregate_Callback.res:26`: command label is bold
   - `StateViewSlice_Callback.res:48`: event type is bold

3. **`LogPrefix.fmtComp` (`reventless-spec/src/LogPrefix.res:150-160`)**
   itself unconditionally injects colour and bold. There is a sibling
   `fmtPlainPrefix` (line 135), but only `Logger.emit`'s Lambda branch
   uses it. `EffectLogger`, `ExtensionPointMapping.compLog`, and
   `ExtensionMapping.compLog` all call `fmtComp` regardless of sink.

The net effect: the architecture *intends* to be sink-aware, but every
helper that touches text formatting is hard-coded to "TTY". Only one
function (`Logger.emit`) actually checks, and the helpers that should have
deferred to it pre-format the string instead.

### The other source: stray `Console.log/.warn/.error`

About 30 unmanaged `Console.*` call sites bypass `Logger.emit` entirely:

- `reventless-aws/src/Platform.res` — ~20 sites in deploy-time hooks
  (`[preAdminResolversSchemaHook]`, `[preResolversSchemaHook]`,
  `[Platform:deployPlatform]`, etc.)
- `reventless-aws/src/Plugin_Stack.res` — CloudFront invalidation hook
- `reventless-aws/src/util/Util_AppSync_Caller.res` — AppSync mutation errors
- `reventless-aws/src/util/Util_StaticBundle.res` — bundle warnings
- `reventless-aws/src/adapter/Cloner/ClonerRunner_Fargate_Runtime.res`
- `reventless-aws/src/adapter/Runtime/StateViewSliceRuntime_Builder_Single.res`

These emit plain text into CloudWatch with their own ad-hoc `[Bracket]`
prefixes, no level, no comp resolution, no JSON shape. They are
filtering- and aggregation-hostile.

### Detection criterion is too narrow

`Logger.emit` checks `process.env.AWS_LAMBDA_FUNCTION_NAME`. That misses:

- Fargate / ECS tasks (Cloner runner, future container deployments)
- Azure Functions, GCP Cloud Run, generic Docker hosts
- CI runners (GitHub Actions) — they have no TTY and currently get raw
  ANSI in workflow logs

A better criterion is `process.stdout.isTTY` (false ⇒ JSON), with an
explicit override env var for power users (`REVENTLESS_LOG_FORMAT=json|text`).

## What "good" looks like for a cloud log sink

CloudWatch, Loki, Datadog, and friends all share the same expectations:

1. **One JSON object per record**. Already done for the Lambda branch.
2. **Top-level fields for what you want to filter on**. Today only `level`
   and `message` exist (plus optional `detail`). Plugin name, component
   name, and correlation id are baked into the `message` string —
   un-filterable.
3. **No control characters in field values**. ANSI escapes destroy the
   "click to expand JSON" affordance in the CloudWatch console and make
   CloudWatch Logs Insights queries match against literal `[1m`.
4. **Correlation/request ids** so a flow across Lambdas can be traced.
   The `RequestContext.correlationId` is already plumbed through Effect
   for business logic — it should also appear on every log line.
5. **Bounded payloads**. CloudWatch caps a single record at 256 KB (1 MB
   for batch put). A `~detail` JSON of a 5 000-event batch will be
   silently truncated by the agent or rejected by `PutLogEvents`.

Target shape:

```json
{
  "time": "2026-06-07T12:43:11.812Z",
  "level": "INFO",
  "plugin": "Catalog",
  "comp": "Aggregate(Product)",
  "message": "handling command 1/1: Add(p-1, {name:\"Cat 1\"})",
  "correlationId": "c-7f3a…",
  "requestId": "5f1e…",
  "detail": { "command": {…}, "meta": {…}, "id": "p-1" }
}
```

The exact same call sites that produce the local terminal line render
into this object — only the emit layer differs.

## Remediation

Three tiers, each independently shippable.

### Tier 1 — stop the bleeding (small, mechanical)

These changes restore clean CloudWatch output without touching any
call site and don't change the local platform's appearance.

1. **Make `AnsiStyle.bold` sink-aware.** Read `process.stdout.isTTY` (or
   the override env) **once** at module init and store the result.
   In a JSON sink, return the input unchanged; in a TTY, wrap with
   `\x1b[1m…\x1b[0m`. Because `LogFormat.bold` re-exports this and every
   `cmdName/eventName/...` formatter goes through it, the fix cascades
   to all callers automatically.

2. **Fix `EffectLogger.withComp` to use the plain prefix in a JSON sink.**
   Replace the unconditional `Logger.fmtComp` with the same `isLambda`/
   TTY check used in `Logger.emit`. Better: keep `withComp` plain and
   move the colouring entirely into `Logger.emit` (single responsibility
   for sink-specific styling).

3. **Generalise the sink detection.** Replace
   `process.env.AWS_LAMBDA_FUNCTION_NAME` with
   `process.stdout.isTTY === false || REVENTLESS_LOG_FORMAT === "json"`.
   Keep the Lambda env var as one signal among several, not the sole
   signal. Cache the decision in a module-level binding so it isn't
   re-evaluated per log call.

4. **Add a regression test.** Extend `tests/logger/LogFormatTest.res`
   with a "JSON sink" mode that asserts the produced JSON `message` field
   contains no `\x1b` characters and that `level`, `comp`, `plugin` are
   distinct top-level keys (after Tier 2). This is the easiest place to
   detect future regressions — the test fails the moment a new helper
   inlines an ANSI code.

Effort: a single PR, < 100 lines changed, no call-site churn.

### Tier 2 — first-class structured fields

Once Tier 1 stops the leaks, promote the things currently baked into
`message` to top-level JSON fields.

5. **Add `plugin` and `comp` as first-class fields.** `Logger.emit`
   already receives `~comp`; resolve `plugin` from
   `LogPrefix.resolvePlugin(~comp?, ())` and pass both into the JSON
   object directly instead of pre-formatting them into the message
   string. The TTY branch still renders `[Plugin][Comp]` exactly as
   today — only the JSON branch changes.

6. **Carry `correlationId` and Lambda `requestId`.** Effect's
   `annotateLogs` API attaches structured key/value pairs to log
   records; the `install()` decoder in `EffectLogger.res` reads them
   off `loggerOptions.annotations` and merges them into the JSON.
   The runtime builders that already set up `RequestContext` (e.g.
   `AggregateRuntime_Builder_Common.res:34`) wrap their handler with
   `Effect.annotateLogs("correlationId", correlationId)` at the same
   layer they create the request context. Lambda's `requestId` comes
   from `context.awsRequestId` in the handler shim.

7. **Route stray `Console.*` through `Logger.emit`.** The 20-odd
   `Console.log("[preResolversSchemaHook] …")` lines in
   `Platform.res` become `log.info(~comp="Platform:deploy", "…")`.
   For Pulumi deploy-time prints, define a top-level
   `let log = Logger.fromEnv()` at the start of each affected module
   and replace `Console.log(...)` site-by-site. The brackets in
   today's free-form text already match what `~comp` produces.

8. **Drop the message-string `\x00` detail encoding.** Today
   `EffectLogger.encode` smuggles structured detail through Effect's
   stringly-typed log payload by joining `message + "\x00" + JSON`,
   and `install()` splits it back out. With Effect annotations
   carrying structured fields, the null-byte trick is unneeded — pass
   detail as an annotation key directly.

Effort: a handful of small PRs; one per concern (fields, correlation
id, stray Console calls). The biggest one is the Console cleanup, but
it is purely mechanical and the diff is grep-able.

### Tier 3 — operational hygiene

9. **Truncate oversized `detail`.** Before stringifying, if
   `JSON.stringify(detail).length > maxDetailBytes` (default 32 KB),
   replace with `{ truncated: true, bytes: N, preview: firstNChars }`.
   Prevents silent record drops on bulk-projection logs.

10. **`time` as RFC 3339 string.** CloudWatch ingests the line's own
    timestamp, but tools downstream of CloudWatch (Insights queries,
    exports to S3) work better with an embedded `time` field. Today
    `hms()` produces a TTY-only `HH:MM:SS`; emit a full ISO timestamp
    in the JSON shape.

11. **Optional `service` field for multi-Lambda deployments.** Derive
    from `process.env.AWS_LAMBDA_FUNCTION_NAME` (or the platform
    namespace in non-Lambda environments). Makes cross-Lambda Insights
    queries trivial: `fields @timestamp, plugin, comp, message | filter service = "OnlineShopCatalogAggrCmd"`.

12. **Sample queries in `docs/guides/`.** A short companion guide —
    "Reading CloudWatch logs from Reventless" — listing 3-5 Insights
    queries the team will actually run (errors by plugin, slow command
    handlers, correlation-id timelines). The structured fields above
    only pay off if people know which queries to type.

## Other-platform notes

The proposed JSON shape is provider-agnostic. The deciding question
for any new platform is just: *does stdout go to a TTY, or to a log
collector?*

- **Local (TTY)**: coloured human format — unchanged.
- **Lambda / Fargate / ECS / CI**: structured JSON.
- **Azure Functions, GCP Cloud Run, generic Docker / k8s**: same
  structured JSON. All major log collectors (Datadog Agent, Vector,
  Fluent Bit, OTel collector) parse top-level JSON automatically.
- **Browser** (if any reventless code ever runs there): the TTY check
  is false, so it would default to JSON. We can add a third branch
  that uses `console.group` / `console.log(level, message, detail)`
  if needed — but that's not on the immediate roadmap.

The point is: every additional sink picks the JSON branch without any
adapter-specific code. The only adapter-specific concern is
"what does CloudWatch / Azure Monitor / … understand best?", and the
answer for all three is "top-level JSON fields".

## Suggested next step

Open a focused PR for Tier 1 (items 1-4). It is mechanically small,
behaviour-preserving for the local platform, and immediately removes
the `[…m` noise from CloudWatch. Tier 2 and Tier 3 follow as
separate PRs once Tier 1 is in.
