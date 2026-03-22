// Compiled entry point for SideEffectHandler Lambda handlers.
// Replaces SideEffectHandlerFactory.mjs + generated entry point code.
// Lives in the Lambda Layer; imported by a static one-line re-export in the code asset.
//
// At cold start:
//   1. Reads HANDLER_CONFIG from env vars
//   2. Dynamically imports user SideEffect modules from /var/task/node_modules/
//   3. Wires SideEffectHandler_Callback.Make({sideEffects, queryEngine})
//   4. Builds handler map keyed by source URN (DynamoDB Stream ARN)
//
// Import paths are build-verified by the ReScript compiler.

// === Dynamic import ===
let dynamicImport: string => promise<'a> = %raw(`(specifier) => import('/var/task/node_modules/' + specifier)`)

// === Process environment ===
@scope("process") @val external env: dict<string> = "env"

// === Config types (parsed from HANDLER_CONFIG env var) ===

type handlerConfig = {
  sideEffectModules: array<string>,
  sourceUrn: string,
}

type config = {handlers: array<handlerConfig>}

// === Build-verified functor imports ===

@module(
  "@reventlessdev/reventless-core/src/components/SideEffectHandler/SideEffectHandler_Callback.res.mjs"
)
external sideEffectHandlerCallbackMake: 'a => 'b = "Make"

@module(
  "@reventlessdev/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_DynamoDbStream_Runtime.res.mjs"
)
external handleStreamEvent: ('a, 'b, 'c) => 'd = "handleStreamEvent"

// === Effect runtime ===

@module("effect/Effect")
external effectProvideService: ('a, 'b) => 'c = "provideService"

@module("effect/Effect")
external effectRunPromise: 'a = "runPromise"

@send external pipe: ('a, 'b) => 'c = "pipe"

// === RequestContext ===

@module("@reventlessdev/reventless-core/src/RequestContext.res.mjs")
external requestContextTag: 'a = "tag"

// === Lambda event accessors ===

@get external getRecords: 'a => Nullable.t<array<'b>> = "Records"
@get external getEventSourceARN: 'a => string = "eventSourceARN"

// === Object constructors ===

let mkNoopQueryEngine: unit => 'a = %raw(`() => ({
  scan: async () => [],
  query: async () => [],
})`)

let mkCallbackSpec: (array<'a>, 'b) => 'c = %raw(`
  (sideEffects, queryEngine) => ({
    sideEffects,
    queryEngine,
  })
`)

let mkSubEvent: array<'a> => 'b = %raw(`(records) => ({Records: records})`)

let mkCtx: option<string> => 'a = %raw(`(cid) => ({correlationId: cid || "unknown"})`)

let callHandler: ('a, 'b, 'c) => 'd = %raw(`(h, e, c) => h(e, c)`)

// === Result field accessors ===

@get external getHandleJsonEvents: 'a => 'b = "handleJsonEvents"

// === Routing helpers ===

let runEffect = (correlationId, effect) =>
  effect
  ->pipe(effectProvideService(requestContextTag, mkCtx(correlationId)))
  ->pipe(effectRunPromise)

let groupBySource = records => {
  let dict: dict<array<'a>> = Dict.make()
  records->Array.forEach(record => {
    let arn = record->getEventSourceARN
    let existing = dict->Dict.get(arn)->Option.getOr([])
    dict->Dict.set(arn, existing->Array.concat([record]))
  })
  dict
}

// === Initialization ===

type streamHandler

let buildAllHandlers = async (): dict<streamHandler> => {
  let configStr = env->Dict.get("HANDLER_CONFIG")->Option.getOr(`{"handlers":[]}`)
  let config: config = configStr->JSON.parseOrThrow->Obj.magic

  let handlers: dict<streamHandler> = Dict.make()

  let _ = await config.handlers
    ->Array.map(async h => {
      // Dynamically import all SideEffect modules for this handler
      let sideEffectModules = await h.sideEffectModules
        ->Array.map(async modPath => await dynamicImport(modPath))
        ->Promise.all

      let noOpQueryEngine = mkNoopQueryEngine()
      let callback = sideEffectHandlerCallbackMake(
        mkCallbackSpec(sideEffectModules, noOpQueryEngine),
      )

      let handler = (event, context) =>
        handleStreamEvent(callback->getHandleJsonEvents, event, context)

      handlers->Dict.set(h.sourceUrn, Obj.magic(handler))
    })
    ->Promise.all

  handlers
}

let initPromise = buildAllHandlers()

// === Exported handler ===

let handler = async (event, context) => {
  let handlers = await initPromise

  let records = event->getRecords->Nullable.toOption->Option.getOr([])
  let grouped = groupBySource(records)

  let _ = await grouped
    ->Dict.toArray
    ->Array.map(async entry => {
      let (arn, subRecords) = entry
      switch handlers->Dict.get(arn) {
      | Some(streamHandler) =>
        Console.log(`----- sideEffectHandler: found handler for ${arn}`)
        let _ = await runEffect(None, callHandler(streamHandler, mkSubEvent(subRecords), context))
      | None => Console.warn(`sideEffectHandler: no handler found: ${arn}`)
      }
    })
    ->Promise.all

  ""
}
