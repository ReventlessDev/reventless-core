// Compiled entry point for ExtensionPoint Lambda handlers.
// Replaces ExtensionPointHandlerFactory.mjs + generated entry point code.
// Lives in the Lambda Layer; imported by a static one-line re-export in the code asset.
//
// At cold start:
//   1. Reads HANDLER_CONFIG from env vars (single handler per Lambda)
//   2. Dynamically imports user Spec/Mappings modules from /var/task/node_modules/
//   3. Wires ExtensionPoint_Callback.Make(config)(spec)(mappings).handleIncomingCommands
//   4. Wires CommandTopic_Callback.Make(spec)(ops).handleJsonCommands
//   5. Routes SQS events through handleQueueEvent

// === Dynamic import ===
let dynamicImport: string => promise<'a> = %raw(`(specifier) => import('/var/task/node_modules/' + specifier)`)

// === Process environment ===
@scope("process") @val external env: dict<string> = "env"

// === Config types ===

type handlerConfig = {
  specModule: string,
  mappingsModule: string,
  queueUrl: string,
  publishToAggregates: dict<string>,
}

type config = handlerConfig

// === Build-verified functor imports ===

@module(
  "@reventlessdev/reventless-core/src/components/ExtensionPoint/ExtensionPoint_Callback.res.mjs"
)
external extensionPointCallbackMake: 'a => 'b => 'c => 'd = "Make"

@module(
  "@reventlessdev/reventless-core/src/components/CommandTopic/CommandTopic_Callback.res.mjs"
)
external commandTopicCallbackMake: 'a => 'b => 'c = "Make"

@module(
  "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs"
)
external handleQueueEvent: ('a, 'b) => 'c = "handleQueueEvent"

@module(
  "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs"
)
external sqsPublishJsons: ('a, string) => 'b = "publishJsons"

// === Helpers ===

@module("./HandlerFactoryHelpers.res.mjs")
external patchSpecId: 'a => 'b = "patchSpecId"

@module("./HandlerFactoryHelpers.res.mjs")
external makeQueueRef: string => 'a = "makeQueueRef"

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
@get external getBody: 'a => Nullable.t<string> = "body"

// === Result field accessors ===

@get external getHandleIncomingCommands: 'a => 'b = "handleIncomingCommands"
@get external getHandleJsonCommands: 'a => 'b = "handleJsonCommands"

// === Object constructors ===

let mkCallbackConfig: ('a, array<'b>, 'c, 'd, 'e) => 'f = %raw(`
  (publishToAggregates, commandTopicResources, scheduler, queryEngine, resourceNaming) => ({
    publishToAggregates,
    commandTopicResources,
    scheduler,
    queryEngine,
    resourceNaming,
  })
`)

let mkCmdTopicCallbackArg: ('a, 'b) => 'c = %raw(`
  (spec, handler) => ({
    Spec: spec,
    commandsHandler: handler,
  })
`)

let mkNoopScheduler: unit => 'a = %raw(`() => ({
  create: async () => { throw new Error("Scheduler not available in bundled ExtensionPoint handler"); },
  delete: async () => { throw new Error("Scheduler not available in bundled ExtensionPoint handler"); },
})`)

let mkNoopQueryEngine: unit => 'a = %raw(`() => ({
  scan: async () => { throw new Error("QueryEngine not available in bundled ExtensionPoint handler"); },
  query: async () => { throw new Error("QueryEngine not available in bundled ExtensionPoint handler"); },
})`)

let mkResourceNaming: unit => 'a = %raw(`() => ({
  name: (n) => n,
  resolve: (n) => n,
})`)

let mkCtx: option<string> => 'a = %raw(`(cid) => ({correlationId: cid || "unknown"})`)

let callHandler: ('a, 'b, 'c) => 'd = %raw(`(h, e, c) => h(e, c)`)

// === Routing helpers ===

let runEffect = (correlationId, effect) =>
  effect
  ->pipe(effectProvideService(requestContextTag, mkCtx(correlationId)))
  ->pipe(effectRunPromise)

let extractCorrelationId = records =>
  records
  ->Array.get(0)
  ->Option.flatMap(r =>
    r
    ->getBody
    ->Nullable.toOption
    ->Option.flatMap(body => {
      try {
        body
        ->JSON.parseOrThrow
        ->JSON.Decode.object
        ->Option.flatMap(obj => obj->Dict.get("meta"))
        ->Option.flatMap(JSON.Decode.object)
        ->Option.flatMap(meta => meta->Dict.get("correlationId"))
        ->Option.flatMap(JSON.Decode.string)
      } catch {
      | _ => None
      }
    })
  )

// === Initialization ===

type sqsHandler

let buildHandler = async (): sqsHandler => {
  let configStr = env->Dict.get("HANDLER_CONFIG")->Option.getOr(`{}`)
  let config: config = configStr->JSON.parseOrThrow->Obj.magic

  let specModule = await dynamicImport(config.specModule)
  let mappingsModule = await dynamicImport(config.mappingsModule)

  let patchedSpec = patchSpecId(specModule)

  // Build publishToAggregates dict from env var queue URLs
  let publishToAggregates: dict<'a> = Dict.make()
  config.publishToAggregates->Dict.forEachWithKey((envVarName, aggName) => {
    let queueUrl = env->Dict.get(envVarName)->Option.getOr("")
    let queue = makeQueueRef(queueUrl)
    publishToAggregates->Dict.set(aggName, sqsPublishJsons(queue, "SQS_FIFO"))
  })

  let callbackConfig = mkCallbackConfig(
    publishToAggregates,
    [],
    mkNoopScheduler(),
    mkNoopQueryEngine(),
    mkResourceNaming(),
  )

  let callback = extensionPointCallbackMake(callbackConfig)(patchedSpec)(mappingsModule)

  let commandTopicCallback = commandTopicCallbackMake(patchedSpec)(
    mkCmdTopicCallbackArg(patchedSpec, callback->getHandleIncomingCommands),
  )

  let resolvedQueue = makeQueueRef(config.queueUrl)
  Obj.magic(handleQueueEvent(resolvedQueue, commandTopicCallback->getHandleJsonCommands))
}

let initPromise = buildHandler()

// === Exported handler ===

let handler = async (event, context) => {
  let sqsHandler = await initPromise

  let records = event->getRecords->Nullable.toOption->Option.getOr([])
  let correlationId = extractCorrelationId(records)

  Console.log(`----- extensionPointHandler: processing ${records->Array.length->Int.toString} record(s)`)
  let _ = await runEffect(correlationId, callHandler(sqsHandler, event, context))
  ""
}
