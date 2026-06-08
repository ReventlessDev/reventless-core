type eventHandler<'event, 'context, 'result> = ('event, 'context) => promise<'result>
type effectHandler<'event, 'context, 'result, 'error> = (
  'event,
  'context,
) => Effect.t<'result, 'error, unit>

// Convert an effectHandler to an eventHandler by providing Logger, RequestContext, and running as promise.
// Used at handler dispatch points (runtime builders) where Effect.runPromise is called.
let runEffectHandler = (handler: effectHandler<'event, 'context, 'result, 'error>): eventHandler<
  'event,
  'context,
  'result,
> =>
  (event, ctx) =>
    handler(event, ctx)
    ->Effect.provideService(RequestContext.tag, RequestContext.test())
    ->Effect.runPromise

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
