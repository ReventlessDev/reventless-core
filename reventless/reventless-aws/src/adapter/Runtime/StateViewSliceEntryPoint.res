// Compiled entry point for StateViewSlice Lambda handlers.
// Replaces StateViewSliceHandlerFactory.mjs + generated entry point code.
// Lives in the Lambda Layer; imported by a static one-line re-export in the code asset.
//
// At cold start:
//   1. Reads HANDLER_CONFIG from env vars
//   2. Dynamically imports user Spec modules from /var/task/node_modules/
//   3. Builds inline jsonEventsHandler: decode → Spec.project → Projection.handleAction
//   4. Builds handler map keyed by source URN (DynamoDB Stream ARN)

// === Dynamic import ===
let dynamicImport: string => promise<'a> = %raw(`(specifier) => import('/var/task/node_modules/' + specifier)`)

// === Process environment ===
@scope("process") @val external env: dict<string> = "env"

// === Config types ===

type handlerConfig = {
  specModule: string,
  queryDbTableName: string,
  sourceUrn: string,
  dcbEventLogModule: option<string>,
}

type config = {handlers: array<handlerConfig>}

// === Build-verified imports ===

@module(
  "@reventlessdev/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_DynamoDbStream_Runtime.res.mjs"
)
external handleStreamEvent: ('a, 'b, 'c) => 'd = "handleStreamEvent"

@module("@reventlessdev/reventless-core/src/Projection.res.mjs")
external projectionHandleAction: ('a, 'b, 'c) => promise<unit> = "handleAction"

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

// sury
@module("sury/src/S.res.mjs")
external parseJsonOrThrow: ('a, 'b) => 'c = "parseJsonOrThrow"

// Effect/Stream
@module("effect/Effect")
external effectSync: (unit => 'a) => 'b = "sync"

@module("effect/Effect")
external effectMap: ('a, 'b => 'c) => 'd = "map"

@module("effect/Effect")
external effectPromise: (unit => promise<'a>) => 'b = "promise"

@module("effect/Stream")
external streamMapEffect: ('a, 'b => 'c) => 'd = "mapEffect"

@module("effect/Stream")
external streamFlatMap: ('a, 'b => 'c) => 'd = "flatMap"

@module("effect/Stream")
external streamFromIterable: 'a => 'b = "fromIterable"

@module("effect/Stream")
external streamRunForEach: ('a, 'b => 'c) => 'd = "runForEach"

// Effect runtime
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

@module("./HandlerFactoryHelpers.res.mjs")
external makeTableRef: string => 'a = "makeTableRef"

let mkQueryDbOps: ('a, 'b, 'c, 'd, 'e, 'f, 'g) => 'h = %raw(`
  (load, loadStream, save, saveBatch, count, del, deleteBatch) => ({
    load, loadStream, save, saveBatch, count, delete: del, deleteBatch,
  })
`)

let mkSubEvent: array<'a> => 'b = %raw(`(records) => ({Records: records})`)

let mkCtx: option<string> => 'a = %raw(`(cid) => ({correlationId: cid || "unknown"})`)

let callHandler: ('a, 'b, 'c) => 'd = %raw(`(h, e, c) => h(e, c)`)

// === Spec module accessors ===

@get external getProject: 'a => 'b = "project"
@get external getDcbEventLogSpec: 'a => 'b = "DcbEventLogSpec"
@get external getEventSchema: 'a => 'b = "eventSchema"

// Extract the "event" field from the DynamoDB stream JSON envelope.
// buildJsonEvent' wraps DynamoDB records as {id, meta, event: <variant_json>},
// but eventSchema expects just the variant JSON.
@get external getEventField: 'a => Nullable.t<'b> = "event"

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

let buildJsonEventsHandler = (specModule, queryDbTableName) => {
  let table = makeTableRef(queryDbTableName)
  let queryDbOps = mkQueryDbOps(
    qdbLoad(table),
    qdbLoadStream(table),
    qdbSave(table),
    qdbSaveBatch(table),
    qdbCount(table),
    qdbDelete(table),
    qdbDeleteBatch(table),
  )

  let eventSchema = specModule->getDcbEventLogSpec->getEventSchema
  let project = specModule->getProject

  // Replicate the inline jsonEventsHandler from StateViewSlice_Builder.construct
  let jsonEventsHandler: 'a => 'b = stream =>
    streamRunForEach(
      streamFlatMap(
        streamMapEffect(stream, json =>
          effectSync(() => {
            try {
              let eventJson = json->getEventField->Nullable.toOption->Option.getOr(json)
              project(None, parseJsonOrThrow(eventJson, eventSchema))
            } catch {
            | exn =>
              Console.log2("StateViewSlice: Failed to decode event:", exn)
              []
            }
          })
        ),
        actions => streamFromIterable(actions),
      ),
      action =>
        effectMap(
          effectPromise(() => projectionHandleAction(action, queryDbOps, None)),
          _ => (),
        ),
    )

  jsonEventsHandler
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
      // Patch DcbEventLogSpec from separately imported event log module
      let patchedSpec = switch h.dcbEventLogModule {
      | Some(modPath) =>
        let _eventLogModule = await dynamicImport(modPath)
        %raw(`Object.assign({}, specModule, { DcbEventLogSpec: _eventLogModule })`)
      | None => specModule
      }
      let jsonEventsHandler = buildJsonEventsHandler(patchedSpec, h.queryDbTableName)

      let handler = (event, context) =>
        handleStreamEvent(jsonEventsHandler, event, context)

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
        Console.log(`----- stateViewSliceHandler: found handler for ${arn}`)
        let _ = await runEffect(None, callHandler(streamHandler, mkSubEvent(subRecords), context))
      | None => Console.warn(`stateViewSliceHandler: no handler found: ${arn}`)
      }
    })
    ->Promise.all

  ""
}
