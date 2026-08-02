type eventHandler<'event, 'context, 'result> = ('event, 'context) => promise<'result>
type effectHandler<'event, 'context, 'result, 'error> = (
  'event,
  'context,
) => Effect.t<'result, 'error, unit>

// ─── Dispatch-boundary annotation ────────────────────────────────────────────
// Single source of truth for what every handler invocation carries. Annotating
// here (rather than in each runtime builder) guarantees that every log line
// inside the handler — framework *and* application — surfaces the same
// `correlationId` / `comp` / `causationId` top-level JSON fields (EffectLogger
// decodes them), and that a populated RequestContext is provided. `comp` is what
// makes two components hosted in one runtime process separable purely by field;
// `causationId` reconstructs the parent → child chain within one `correlationId`.
let annotateInvocation = (
  effect,
  ~correlationId=?,
  ~causationId=?,
  ~comp=?,
  ~pluginName=?,
  ~timestamp=?,
  ~retryCount=?,
  ~identity=?,
  ~claims=?,
) => {
  let cid = correlationId->Option.getOr("unknown")
  // Resolve the owning plugin from the comp→plugin registry when not supplied,
  // so RequestContext.pluginName matches the `plugin` log field (which
  // EffectLogger.install resolves the same way via LogPrefix.resolvePlugin).
  let resolvedPlugin = switch pluginName {
  | Some(_) => pluginName
  | None => Reventless.LogPrefix.resolvePlugin(~comp?, ())
  }
  let annotateOpt = (eff, key, value) =>
    switch value {
    | Some(v) => eff->Effect.annotateLogs(key, v)
    | None => eff
    }
  // Only a redelivery is annotated: a constant "1" on every line is noise, and
  // its absence is what makes `retryCount > 1` a usable filter. `timestamp` is
  // never annotated — it is a context field for computing latency, not a key
  // anyone filters on.
  let annotateRetry = eff =>
    switch retryCount {
    | Some(count) if count > 1 => eff->Effect.annotateLogs("retryCount", count->Int.toString)
    | _ => eff
    }
  effect
  ->Effect.annotateLogs("correlationId", cid)
  ->annotateOpt("comp", comp)
  ->annotateOpt("causationId", causationId)
  ->annotateRetry
  ->Effect.provideService(
    RequestContext.tag,
    RequestContext.make(
      ~correlationId=cid,
      ~causationId?,
      ~component=?comp,
      ~pluginName=?resolvedPlugin,
      ~timestamp?,
      ~retryCount?,
      ~identity?,
      ~claims?,
    ),
  )
}

// Annotate + run. Used by the multi-component dispatchers (AllAggregates,
// AllEventCollectors) that loop over per-source handlers, and by any dispatch
// site that already holds the invocation's identity (e.g. the MCP tool caller).
let runEffect = (
  ~correlationId=?,
  ~causationId=?,
  ~comp=?,
  ~pluginName=?,
  ~timestamp=?,
  ~retryCount=?,
  ~identity=?,
  ~claims=?,
  effect,
) =>
  effect
  ->annotateInvocation(
    ~correlationId?,
    ~causationId?,
    ~comp?,
    ~pluginName?,
    ~timestamp?,
    ~retryCount?,
    ~identity?,
    ~claims?,
  )
  ->Effect.runPromise

// Convert an effectHandler to an eventHandler at build time, annotating the
// invocation on each call. Used by the single-component-per-Lambda strategies
// (Micro / PerAggregate / Plugin / PerEventCollector / PerExtensionPoint), which
// pass the Environment's `extractCorrelationId` / `extractCausationId` and the
// component `comp` so their application handlers get the same fields as the
// multi-component path. Extractors default to none for generic use.
let runEffectHandler = (
  ~extractCorrelationId: option<'event => option<string>>=?,
  ~extractCausationId: option<'event => option<string>>=?,
  ~extractSentTimestamp: option<'event => option<float>>=?,
  ~extractRetryCount: option<'event => option<int>>=?,
  ~comp=?,
  ~pluginName=?,
  handler: effectHandler<'event, 'context, 'result, 'error>,
): eventHandler<'event, 'context, 'result> =>
  (event, ctx) => {
    let extract = (f, event) =>
      switch f {
      | Some(f) => f(event)
      | None => None
      }
    let correlationId = extractCorrelationId->extract(event)
    let causationId = extractCausationId->extract(event)
    let timestamp = extractSentTimestamp->extract(event)
    let retryCount = extractRetryCount->extract(event)
    handler(event, ctx)
    ->annotateInvocation(
      ~correlationId?,
      ~causationId?,
      ~comp?,
      ~pluginName?,
      ~timestamp?,
      ~retryCount?,
    )
    ->Effect.runPromise
  }

type environment<'parts> = {
  parts: 'parts,
  resources: array<ReventlessInfra.Adapter.resource>,
}

type environmentMaker<'event, 'context, 'result, 'parts> = (
  ~name: string,
  ~handler: Pulumi.Output.t<eventHandler<'event, 'context, 'result>>,
  ~memorySize: int=?,
  ~timeout: int=?,
  ~opts: Pulumi.ComponentResource.options=?,
) => environment<'parts>

module type Environment = {
  type event
  type context
  type parts
  let make: environmentMaker<event, context, 'result, parts>
  let groupBySource: event => dict<event>
  let extractCorrelationId: event => option<string>
  let extractCausationId: event => option<string>
  // Transport-level delivery facts, for RequestContext.timestamp / .retryCount.
  // `None` where the transport carries no such notion (see each implementation).
  let extractSentTimestamp: event => option<float>
  let extractRetryCount: event => option<int>
  let asEventHandler: 'a => eventHandler<event, context, 'result>
  let asEffectHandler: 'a => effectHandler<event, context, 'result, 'error>
}

type connect<'parts> = (~runtime: environment<'parts>) => unit

type forComponent<'handler, 'parts, 'component> = (
  ~handler: Pulumi.Output.t<'handler>,
  ~connect: connect<'parts>,
  ~memorySize: int=?,
  ~timeout: int=?,
  'component,
) => unit

type forComponentNamed<'handler, 'parts, 'component> = (
  ~handler: Pulumi.Output.t<'handler>,
  ~connect: connect<'parts>,
  ~memorySize: int=?,
  ~timeout: int=?,
  ~name: string,
  'component,
) => unit

type forEventCollector<'handler, 'component> = (
  ~handler: Pulumi.Output.t<'handler>,
  ~eventTopics: EventTopic.allOutputs,
  ~resources: array<ReventlessInfra.Adapter.resource>,
  ~memorySize: int=?,
  ~timeout: int=?,
  'component,
) => unit

// commandHandlerConfig — per-Lambda tuning for the four command-handler Lambdas:
// AllAggregatesCmdHandler (sync), AllAggregatesAsyncCmdHandler,
// <Plugin>DcbCmdHandler (sync), <Plugin>DcbAsyncCmdHandler. Every field is
// optional; the framework fills
// unset fields from CommandHandlerDefaults below. Transport-neutral: the
// AWS platform maps fields to Lambda/SQS/CloudWatch primitives; the
// in-memory platform honors envVars and ignores the rest.
type commandHandlerConfig = {
  memorySize?: int,
  timeout?: int,
  reservedConcurrency?: int,
  sqsBatchSize?: int,
  ephemeralStorageMb?: int,
  logRetentionDays?: int,
  // Minimum log level for this handler ("silent" | "error" | "warn" | "info" |
  // "debug"), mapped onto the `LOG_LEVEL` env var the logger reads. Overrides the
  // per-environment tier default. Transport-neutral: the in-memory platform reads
  // it the same way via the env var.
  logLevel?: string,
  envVars?: dict<string>,
}

type commandHandlerConfigFlavors = {
  sync?: commandHandlerConfig,
  async?: commandHandlerConfig,
}

type commandHandlerConfigs = {
  aggregates?: commandHandlerConfigFlavors,
  stateChanges?: commandHandlerConfigFlavors,
}

// Framework defaults applied when commandHandlerConfig fields are omitted.
// Single source of truth — readable and composable by app developers.
module CommandHandlerDefaults = {
  let memorySize = 1024
  let timeout = 30
  let sqsBatchSize = 10
  let ephemeralStorageMb = 512
  // No `logRetentionDays` / `logLevel` default here: both are resolved per
  // environment tier by the AWS platform (`Util_LogRetention`), not by a flat
  // framework constant. An unset field means "follow the stack's tier", which a
  // single number could not express.
}
