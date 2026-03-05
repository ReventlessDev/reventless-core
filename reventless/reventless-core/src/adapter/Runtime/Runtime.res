type eventHandler<'event, 'context, 'result> = ('event, 'context) => promise<'result>
type effectHandler<'event, 'context, 'result, 'error> = ('event, 'context) => Effect.t<'result, 'error, unit>

// Convert an effectHandler to an eventHandler by providing Logger and running as promise.
// Used at handler dispatch points (runtime builders) where Effect.runPromise is called.
let runEffectHandler = (handler: effectHandler<'event, 'context, 'result, 'error>): eventHandler<
  'event,
  'context,
  'result,
> =>
  (event, ctx) =>
    handler(event, ctx)
    ->Effect.provideService(EffectLogger.tag, EffectLogger.consoleLogger)
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

// Simple synchronous logger for runtime builder diagnostics.
// Separate from the Effect-based Logger.t (which lives in rescript-effect
// and is shadowed by Logger.res in this package).
type runtimeLogger = {
  info: string => unit,
  warn: string => unit,
}

let defaultLogger: runtimeLogger = {
  info: msg => Console.log(msg),
  warn: msg => Console.warn(msg),
}

let silentLogger: runtimeLogger = {
  info: _ => (),
  warn: _ => (),
}

module type Environment = {
  type event
  type context
  type parts
  let make: environmentMaker<event, context, 'result, parts>
  let groupBySource: event => dict<event>
  let asEventHandler: 'a => eventHandler<event, context, 'result>
  let asEffectHandler: 'a => effectHandler<event, context, 'result, 'error>
  let logger: runtimeLogger
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
