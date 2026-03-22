// Compiled entry point for ReadModel Lambda handlers.
// Replaces ReadModelHandlerFactory.mjs + generated entry point code.
// Lives in the Lambda Layer; imported by a static one-line re-export in the code asset.
//
// At cold start:
//   1. Reads HANDLER_CONFIG from env vars
//   2. Dynamically imports user Spec/Mappings modules from /var/task/node_modules/
//   3. Wires ReadModel_Callback.Make(Spec)(Mappings)({ReadModelSpec, operations})
//   4. Builds handler map keyed by source URN (DynamoDB Stream ARN)

// === Dynamic import ===
let dynamicImport: string => promise<'a> = %raw(`(specifier) => import('/var/task/node_modules/' + specifier)`)

// === Process environment ===
@scope("process") @val external env: dict<string> = "env"

// === Config types ===

type handlerConfig = {
  specModule: string,
  mappingsModule: string,
  queryDbTableName: string,
  sourceUrn: string,
}

type config = {handlers: array<handlerConfig>}

// === Build-verified functor imports ===

@module(
  "@reventlessdev/reventless-core/src/components/ReadModel/ReadModel_Callback.res.mjs"
)
external readModelCallbackMake: 'a => 'b => 'c => 'd = "Make"

@module(
  "@reventlessdev/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_DynamoDbStream_Runtime.res.mjs"
)
external handleStreamEvent: ('a, 'b, 'c) => 'd = "handleStreamEvent"

// QueryDb runtime operations
@module(
  "@reventlessdev/reventless-aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res.mjs"
)
external qdbLoad: 'a => 'b = "load"

@module(
  "@reventlessdev/reventless-aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res.mjs"
)
external qdbLoadStream: 'a => 'b = "loadStream"

@module(
  "@reventlessdev/reventless-aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res.mjs"
)
external qdbSave: 'a => 'b = "save"

@module(
  "@reventlessdev/reventless-aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res.mjs"
)
external qdbSaveBatch: 'a => 'b = "saveBatch"

@module(
  "@reventlessdev/reventless-aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res.mjs"
)
external qdbCount: 'a => 'b = "count"

@module(
  "@reventlessdev/reventless-aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res.mjs"
)
external qdbDelete: 'a => 'b = "$$delete"

@module(
  "@reventlessdev/reventless-aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res.mjs"
)
external qdbDeleteBatch: 'a => 'b = "deleteBatch"

// === Helpers ===

@module("./HandlerFactoryHelpers.res.mjs")
external patchSpecId: 'a => 'b = "patchSpecId"

@module("./HandlerFactoryHelpers.res.mjs")
external makeTableRef: string => 'a = "makeTableRef"

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

// === Object constructors ===

// ReadModel_Callback.Make needs: ReadModelSpec (the spec), operations (QueryDb ops)
let mkReadModelCallbackArg: ('a, 'b) => 'c = %raw(`
  (spec, operations) => ({
    ReadModelSpec: spec,
    operations,
  })
`)

// Inject 'id' key into saved state objects (replicates ReadModel_Callback's id injection)
let mkInjectIdSave: 'a => 'b = %raw(`
  (rawSave) => (id, state, saveMode, ttl) => {
    const injected = (state && typeof state === "object" && !Array.isArray(state))
      ? { ...state, id }
      : state;
    return rawSave(id, injected, saveMode, ttl);
  }
`)

let mkInjectIdSaveBatch: 'a => 'b = %raw(`
  (rawSaveBatch) => (items) =>
    rawSaveBatch(items.map(([id, state, ttl]) => {
      const injected = (state && typeof state === "object" && !Array.isArray(state))
        ? { ...state, id }
        : state;
      return [id, injected, ttl];
    }))
`)

let mkOperations: ('a, 'b, 'c, 'd, 'e, 'f, 'g) => 'h = %raw(`
  (load, loadStream, save, saveBatch, count, del, deleteBatch) => ({
    load, loadStream, save, saveBatch, count, delete: del, deleteBatch,
  })
`)

// Fix mappings module: ensure it has a `mappings` array
let fixMappingsModule: 'a => 'b = %raw(`
  (mod) => {
    if (mod.mappings) return mod;
    const mappingValues = Object.values(mod).filter(
      (v) => v && typeof v === "object" && "sourceName" in v && "map" in v
    );
    if (mappingValues.length > 0) {
      return { ...mod, mappings: mappingValues };
    }
    return mod;
  }
`)

let mkSubEvent: array<'a> => 'b = %raw(`(records) => ({Records: records})`)

let mkCtx: option<string> => 'a = %raw(`(cid) => ({correlationId: cid || "unknown"})`)

let callHandler: ('a, 'b, 'c) => 'd = %raw(`(h, e, c) => h(e, c)`)

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

// === Handler builder ===

let buildReadModelHandler = (specModule, mappingsModule, queryDbTableName) => {
  let patchedSpec = patchSpecId(specModule)
  let table = makeTableRef(queryDbTableName)

  let rawSave = qdbSave(table)
  let rawSaveBatch = qdbSaveBatch(table)

  let operations = mkOperations(
    qdbLoad(table),
    qdbLoadStream(table),
    mkInjectIdSave(rawSave),
    mkInjectIdSaveBatch(rawSaveBatch),
    qdbCount(table),
    qdbDelete(table),
    qdbDeleteBatch(table),
  )

  let effectiveMappings = fixMappingsModule(mappingsModule)

  let callback = readModelCallbackMake(patchedSpec)(effectiveMappings)(
    mkReadModelCallbackArg(patchedSpec, operations),
  )

  (event, context) =>
    handleStreamEvent(callback->getHandleJsonEvents, event, context)
}

// === Initialization ===

type streamHandler

let buildAllHandlers = async (): dict<streamHandler> => {
  let configStr = env->Dict.get("HANDLER_CONFIG")->Option.getOr(`{"handlers":[]}`)
  let config: config = configStr->JSON.parseOrThrow->Obj.magic

  let handlers: dict<streamHandler> = Dict.make()

  let _ = await config.handlers
    ->Array.map(async h => {
      let specModule = await dynamicImport(h.specModule)
      let mappingsModule = await dynamicImport(h.mappingsModule)

      let handler = buildReadModelHandler(specModule, mappingsModule, h.queryDbTableName)
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
        Console.log(`----- readModelHandler: found handler for ${arn}`)
        let _ = await runEffect(None, callHandler(streamHandler, mkSubEvent(subRecords), context))
      | None => Console.warn(`readModelHandler: no handler found: ${arn}`)
      }
    })
    ->Promise.all

  ""
}
