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
) => {
  let cid = correlationId->Option.getOr("unknown")
  let annotateOpt = (eff, key, value) =>
    switch value {
    | Some(v) => eff->Effect.annotateLogs(key, v)
    | None => eff
    }
  effect
  ->Effect.annotateLogs("correlationId", cid)
  ->annotateOpt("comp", comp)
  ->annotateOpt("causationId", causationId)
  ->Effect.provideService(
    RequestContext.tag,
    RequestContext.make(~correlationId=cid, ~causationId?, ~component=?comp, ~pluginName?),
  )
}

// Annotate + run. Used by the multi-component dispatchers (AllAggregates,
// AllEventCollectors) that loop over per-source handlers.
let runEffect = (~correlationId=?, ~causationId=?, ~comp=?, ~pluginName=?, effect) =>
  effect
  ->annotateInvocation(~correlationId?, ~causationId?, ~comp?, ~pluginName?)
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
  ~comp=?,
  ~pluginName=?,
  handler: effectHandler<'event, 'context, 'result, 'error>,
): eventHandler<'event, 'context, 'result> =>
  (event, ctx) => {
    let correlationId = switch extractCorrelationId {
    | Some(f) => f(event)
    | None => None
    }
    let causationId = switch extractCausationId {
    | Some(f) => f(event)
    | None => None
    }
    handler(event, ctx)
    ->annotateInvocation(~correlationId?, ~causationId?, ~comp?, ~pluginName?)
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
  let logRetentionDays = 7
}
