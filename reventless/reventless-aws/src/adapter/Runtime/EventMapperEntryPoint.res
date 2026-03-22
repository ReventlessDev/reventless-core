// Compiled entry point for EventMapper Lambda handlers (Micro mode).
// Replaces EventMapperHandlerFactory.mjs + generated entry point code.
// Lives in the Lambda Layer; imported by a static one-line re-export in the code asset.
//
// At cold start:
//   1. Reads HANDLER_CONFIG from env vars
//   2. Dynamically imports user Target Spec and Mappings modules
//   3. Wires EventMapper_Callback.MakeCounterHandler + MakeEventCollectorHandler
//   4. Routes DynamoDB Stream events

// === Dynamic import ===
let dynamicImport: string => promise<'a> = %raw(`(specifier) => import('/var/task/node_modules/' + specifier)`)

// === Process environment ===
@scope("process") @val external env: dict<string> = "env"

// === Config types ===

type handlerConfig = {
  targetSpecModule: string,
  mappingsModule: string,
  queueUrl: string,
}

type config = handlerConfig

// === Build-verified functor imports ===

@module(
  "@reventlessdev/reventless-core/src/components/EventMapper/EventMapper_Callback.res.mjs"
)
external makeCounterHandler: 'a => 'b => 'c => 'd = "MakeCounterHandler"

@module(
  "@reventlessdev/reventless-core/src/components/EventMapper/EventMapper_Callback.res.mjs"
)
external makeEventCollectorHandler: 'a => 'b = "MakeEventCollectorHandler"

@module(
  "@reventlessdev/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_DynamoDbStream_Runtime.res.mjs"
)
external handleStreamEvent: ('a, 'b, 'c) => 'd = "handleStreamEvent"

@module(
  "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs"
)
external sqsPublishJsons: ('a, string) => 'b = "publishJsons"

@module("@reventlessdev/reventless-spec/src/types/Id.res.mjs")
external idString: 'a = "$$String"

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
@get external getEventSourceARN: 'a => string = "eventSourceARN"

// === Result field accessors ===

@get external getHandleJsonEvents: 'a => 'b = "handleJsonEvents"
@get external getCommonEventsHandler: 'a => 'b = "commonEventsHandler"

// === Object constructors ===

// Patch Source.Id on each mapping
let patchMappingsSourceIds: 'a => 'b = %raw(`
  (mappingsModule) => ({
    ...mappingsModule,
    mappings: (mappingsModule.mappings || []).map((mapping) => ({
      ...mapping,
      Source: {
        ...mapping.Source,
        Id: mapping.Source.Id || IdString,
      },
    })),
  })
`)

// Use IdString from the imported module
@module("@reventlessdev/reventless-spec/src/types/Id.res.mjs")
external _idString: 'a = "$$String"

let mkCounterOps: ('a, 'b) => 'c = %raw(`
  (publishJsons, queryEngine) => ({
    publishJsons,
    queryEngine,
  })
`)

let mkEventCollectorOps: ('a, 'b, 'c, 'd) => 'e = %raw(`
  (publishJsons, count, addToCounterTarget, commonEventsHandler) => ({
    publishJsons,
    count,
    addToCounterTarget,
    commonEventsHandler,
  })
`)

let mkNoopQueryEngine: unit => 'a = %raw(`() => ({
  query: async () => { console.error("EventMapper queryEngine not available in bundled mode"); return []; },
  get: async () => { console.error("EventMapper queryEngine not available in bundled mode"); return undefined; },
})`)

let mkSubEvent: array<'a> => 'b = %raw(`(records) => ({Records: records})`)
let mkCtx: option<string> => 'a = %raw(`(cid) => ({correlationId: cid || "unknown"})`)
let callHandler: ('a, 'b, 'c) => 'd = %raw(`(h, e, c) => h(e, c)`)
let noopAsync: unit => 'a = %raw(`() => (async (_) => {})`)

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

let buildHandler = async (): streamHandler => {
  let configStr = env->Dict.get("HANDLER_CONFIG")->Option.getOr(`{}`)
  let config: config = configStr->JSON.parseOrThrow->Obj.magic

  let targetSpecModule = await dynamicImport(config.targetSpecModule)
  let mappingsModule = await dynamicImport(config.mappingsModule)

  let patchedTarget = patchSpecId(targetSpecModule)
  let patchedMappings = patchMappingsSourceIds(mappingsModule)

  let publishJsons = sqsPublishJsons(makeQueueRef(config.queueUrl), "SQS_FIFO")
  let queryEngine = mkNoopQueryEngine()

  let counterHandler = makeCounterHandler(patchedTarget)(patchedMappings)(
    mkCounterOps(publishJsons, queryEngine),
  )

  let eventCollectorHandler = makeEventCollectorHandler(
    mkEventCollectorOps(
      publishJsons,
      noopAsync(),
      noopAsync(),
      counterHandler->getCommonEventsHandler,
    ),
  )

  Obj.magic(
    (event, context) =>
      handleStreamEvent(eventCollectorHandler->getHandleJsonEvents, event, context),
  )
}

let initPromise = buildHandler()

// === Exported handler ===

let handler = async (event, context) => {
  let streamHandler = await initPromise

  let records = event->getRecords->Nullable.toOption->Option.getOr([])
  let grouped = groupBySource(records)

  let _ = await grouped
    ->Dict.toArray
    ->Array.map(async entry => {
      let (arn, subRecords) = entry
      Console.log(`----- eventMapperHandler: processing ${arn}`)
      let _ = await runEffect(None, callHandler(streamHandler, mkSubEvent(subRecords), context))
    })
    ->Promise.all

  ""
}
