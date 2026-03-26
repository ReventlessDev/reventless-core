// Compiled entry point for AutomationSlice and OutboundTranslationSlice Lambda handlers.
// Replaces AutomationSliceHandlerFactory.mjs + generated entry point code.
// Lives in the Lambda Layer; imported by a static one-line re-export in the code asset.
//
// At cold start:
//   1. Reads HANDLER_CONFIG from env vars
//   2. Dynamically imports user Spec modules from /var/task/node_modules/
//   3. Wires AutomationSlice_Callback.Make(Spec) or OutboundTranslationSlice_Callback.Make(Spec)
//   4. Builds handler map keyed by source URN (DynamoDB Stream ARN)

// === Dynamic import ===
let dynamicImport: string => promise<'a> = %raw(`(specifier) => import('/var/task/node_modules/' + specifier)`)

// === Process environment ===
@scope("process") @val external env: dict<string> = "env"

// === Config types ===

type handlerConfig = {
  specModule: string,
  callbackType: string,
  queryDbTableName: string,
  dcbQueueUrl: string,
  sourceUrn: string,
}

type config = {handlers: array<handlerConfig>}

// === Build-verified functor imports ===

@module(
  "@reventlessdev/reventless-core/src/components/AutomationSlice/AutomationSlice_Callback.res.mjs"
)
external automationSliceCallbackMake: 'a => 'b = "Make"

@module(
  "@reventlessdev/reventless-core/src/components/OutboundTranslationSlice/OutboundTranslationSlice_Callback.res.mjs"
)
external outboundTranslationSliceCallbackMake: 'a => 'b = "Make"

@module(
  "@reventlessdev/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_DynamoDbStream_Runtime.res.mjs"
)
external handleStreamEvent: ('a, 'b, 'c) => 'd = "handleStreamEvent"

// QueryDb runtime
@module(
  "@reventlessdev/reventless-aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res.mjs"
)
external qdbSave: 'a => 'b = "save"

// SQS runtime
@module(
  "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs"
)
external sqsPublishJsons: ('a, string) => 'b = "publishJsons"

// sury
@module("sury/src/S.res.mjs")
external parseJsonOrThrow: ('a, 'b) => 'c = "parseJsonOrThrow"

// Effect/Stream
@module("effect/Effect")
external effectFlatMap: ('a, 'b => 'c) => 'd = "flatMap"

@module("effect/Effect")
external effectSync: (unit => 'a) => 'b = "sync"

@module("effect/Effect")
external effectPromise: (unit => promise<'a>) => 'b = "promise"

@module("effect/Stream")
external streamMapEffect: ('a, 'b => 'c) => 'd = "mapEffect"

@module("effect/Stream")
external streamFlatMap: ('a, 'b => 'c) => 'd = "flatMap"

@module("effect/Stream")
external streamFromIterable: 'a => 'b = "fromIterable"

@module("effect/Stream")
external streamRunCollect: 'a => 'b = "runCollect"

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

// === Helpers ===

@module("./HandlerFactoryHelpers.res.mjs")
external makeTableRef: string => 'a = "makeTableRef"

@module("./HandlerFactoryHelpers.res.mjs")
external makeQueueRef: string => 'a = "makeQueueRef"

// === Object/field accessors ===

@get external getTodoItems: 'a => 'b = "todoItems"
@get external getContents: 'a => 'b = "contents"
@get external getPhase1: 'a => 'b = "phase1"
@get external getPhase2: 'a => 'b = "phase2"
@get external getConsumedEventSchema: 'a => 'b = "consumedEventSchema"
@get external getEventField: 'a => Nullable.t<'b> = "event"

let mkSubEvent: array<'a> => 'b = %raw(`(records) => ({Records: records})`)
let mkCtx: option<string> => 'a = %raw(`(cid) => ({correlationId: cid || "unknown"})`)
let callHandler: ('a, 'b, 'c) => 'd = %raw(`(h, e, c) => h(e, c)`)
let callPhase1: ('a, 'b) => unit = %raw(`(fn, arr) => fn(arr)`)
let callPhase2: ('a, 'b) => promise<unit> = %raw(`(fn, publishJsons) => fn(publishJsons)`)
let callSave: ('a, string, 'b, string, 'c) => promise<unit> = %raw(`(fn, id, row, mode, ttl) => fn(id, row, mode, ttl)`)
let objectEntries: 'a => array<(string, 'b)> = %raw(`(obj) => Object.entries(obj)`)

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

let buildHandler = (specModule, callbackMake, queryDbTableName, dcbQueueUrl) => {
  let callback = callbackMake(specModule)
  let publishJsons = sqsPublishJsons(makeQueueRef(dcbQueueUrl), "SQS_FIFO")
  let table = makeTableRef(queryDbTableName)
  let rawSave = qdbSave(table)

  let syncToQueryDb = async () => {
    let items = callback->getTodoItems->getContents->objectEntries
    let _ = await items
      ->Array.map(async entry => {
        let (id, row) = entry
        await callSave(rawSave, id, row, "Overwrite", Obj.magic(None))
      })
      ->Promise.all
  }

  let eventSchema = specModule->getConsumedEventSchema

  let jsonEventsHandler: 'a => 'b = stream =>
    effectFlatMap(
      streamRunCollect(
        streamFlatMap(
          streamMapEffect(stream, json =>
            effectSync(() => {
              try {
                let eventJson = json->getEventField->Nullable.toOption->Option.getOr(json)
                [parseJsonOrThrow(eventJson, eventSchema)]
              } catch {
              | exn =>
                Console.log2("AutomationSlice: Failed to decode event:", exn)
                []
              }
            })
          ),
          events => streamFromIterable(events),
        ),
      ),
      eventsArr =>
        effectPromise(async () => {
          callPhase1(callback->getPhase1, eventsArr)
          await callPhase2(callback->getPhase2, publishJsons)
          await syncToQueryDb()
        }),
    )

  (event, context) =>
    handleStreamEvent(jsonEventsHandler, event, context)
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
      let callbackMake = switch h.callbackType {
      | "outbound" => outboundTranslationSliceCallbackMake
      | _ => automationSliceCallbackMake
      }

      let handler = buildHandler(specModule, callbackMake, h.queryDbTableName, h.dcbQueueUrl)
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
        Console.log(`----- automationSliceHandler: found handler for ${arn}`)
        let _ = await runEffect(None, callHandler(streamHandler, mkSubEvent(subRecords), context))
      | None => Console.warn(`automationSliceHandler: no handler found: ${arn}`)
      }
    })
    ->Promise.all

  ""
}
