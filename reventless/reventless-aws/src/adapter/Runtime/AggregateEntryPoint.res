// Compiled entry point for aggregate Lambda handlers.
// Replaces AggregateHandlerFactory.mjs + generated entry point code.
// Lives in the Lambda Layer; imported by a static one-line re-export in the code asset.
//
// At cold start:
//   1. Reads HANDLER_CONFIG from env vars
//   2. Dynamically imports user Spec/Behavior modules from /var/task/node_modules/
//   3. Wires functor chains (EventLog_Operations, Aggregate_Callback, CommandTopic_Callback)
//   4. Builds handler maps keyed by queue ARN (SQS) and spec name (AppSync)
//
// Import paths are build-verified by the ReScript compiler.

// === Dynamic import ===
// User modules live in the Lambda code asset at /var/task/node_modules/.
// ESM import() resolves relative to the importing module (this file, in the Layer
// at /opt/nodejs/node_modules/), so we must use absolute paths to reach the code asset.
let dynamicImport: string => promise<'a> = %raw(`(specifier) => import('/var/task/node_modules/' + specifier)`)

// === Process environment ===
@scope("process") @val external env: dict<string> = "env"

// === Config types (parsed from HANDLER_CONFIG env var) ===

type handlerConfig = {
  specModule: string,
  behaviorModule: string,
  eventLogTable: string,
  queueUrl: string,
  queueArn: string,
}

type config = {handlers: array<handlerConfig>}

// === Build-verified functor imports ===
// ReScript functors compile to curried JS functions.
// Using @module externals keeps import paths compiler-verified while allowing
// dynamic (runtime-loaded) module arguments.

@module("@reventlessdev/reventless-core/src/components/EventLog/EventLog_Operations.res.mjs")
external eventLogOperationsMake: 'a => 'b => 'c = "Make"

@module("@reventlessdev/reventless-core/src/components/Aggregate/Aggregate_Callback.res.mjs")
external aggregateCallbackMake: 'a => 'b => 'c => 'd = "Make"

@module(
  "@reventlessdev/reventless-core/src/components/CommandTopic/CommandTopic_Callback.res.mjs"
)
external commandTopicCallbackMake: 'a => 'b => 'c = "Make"

@module(
  "@reventlessdev/reventless-core/src/components/CommandGenerator/CommandGenerator_Callback.res.mjs"
)
external makeGenerateCommand: ('a, string, 'b, option<bool>) => 'c = "makeGenerateCommand"

// === EventLog storage operations ===

@module(
  "@reventlessdev/reventless-aws/src/adapter/EventLog/EventLogStorage_DynamoDb_Runtime.res.mjs"
)
external elAppend: 'a => 'b = "append"

@module(
  "@reventlessdev/reventless-aws/src/adapter/EventLog/EventLogStorage_DynamoDb_Runtime.res.mjs"
)
external elReplay: 'a => 'b = "replay"

@module(
  "@reventlessdev/reventless-aws/src/adapter/EventLog/EventLogStorage_DynamoDb_Runtime.res.mjs"
)
external elReplayStream: 'a => 'b = "replayStream"

@module(
  "@reventlessdev/reventless-aws/src/adapter/EventLog/EventLogStorage_DynamoDb_Runtime.res.mjs"
)
external elAppendStream: 'a => 'b = "appendStream"

// === SQS runtime ===

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
@get external getCommand: 'a => Nullable.t<string> = "command"
@get external getArguments: 'a => Nullable.t<'b> = "arguments"
@get external getEventSourceARN: 'a => string = "eventSourceARN"
@get external getBody: 'a => Nullable.t<string> = "body"

// === Result field accessors ===

@get external getHandleCommands: 'a => 'b = "handleCommands"
@get external getHandleJsonCommands: 'a => 'b = "handleJsonCommands"
@get external getName: 'a => string = "name"
@get external getCommandSchema: 'a => 'b = "commandSchema"

// === Object constructors for functor arguments ===
// JS objects with capital-letter keys (Spec, EventTopic, EventLog) can't be
// expressed as ReScript record literals, so we use %raw helper functions.

let mkNameObj: string => 'a = %raw(`(name) => ({name})`)

let mkEventLogOpsArg: ('a, 'b, 'c) => 'd = %raw(`
  (spec, eventTopicOps, storageOps) => ({
    Spec: spec,
    EventTopic: { Spec: spec },
    eventTopic: eventTopicOps,
    storage: storageOps,
  })
`)

let mkAggCallbackArg: ('a, 'b) => 'c = %raw(`
  (spec, eventLogOps) => ({
    Spec: spec,
    EventLog: { Spec: spec },
    eventLog: eventLogOps,
  })
`)

let mkCmdTopicCallbackArg: ('a, 'b) => 'c = %raw(`
  (spec, handler) => ({
    Spec: spec,
    commandsHandler: handler,
  })
`)

let mkNoopEventTopicOps: unit => 'a = %raw(`() => ({publish: async () => {}})`)

let mkStorageOps: ('a, 'b, 'c, 'd) => 'e = %raw(`
  (append, replay, replayStream, appendStream) => ({append, replay, replayStream, appendStream})
`)

let mkSubEvent: array<'a> => 'b = %raw(`(records) => ({Records: records})`)

let mkCtx: option<string> => 'a = %raw(`(cid) => ({correlationId: cid || "unknown"})`)

let callHandler: ('a, 'b, 'c) => 'd = %raw(`(h, e, c) => h(e, c)`)

// === Handler builders ===

let buildCommandTopicHandler = (specModule, behaviorModule, eventLogTableName, queueUrl) => {
  let patchedSpec = patchSpecId(specModule)
  let resolvedTable = mkNameObj(eventLogTableName)
  let rawStorageOps = mkStorageOps(
    elAppend(resolvedTable),
    elReplay(resolvedTable),
    elReplayStream(resolvedTable),
    elAppendStream(resolvedTable),
  )
  let eventLogOps = eventLogOperationsMake(patchedSpec)(
    mkEventLogOpsArg(patchedSpec, mkNoopEventTopicOps(), rawStorageOps),
  )
  let aggregateCallback = aggregateCallbackMake(patchedSpec)(behaviorModule)(
    mkAggCallbackArg(patchedSpec, eventLogOps),
  )
  let commandTopicCallback = commandTopicCallbackMake(patchedSpec)(
    mkCmdTopicCallbackArg(patchedSpec, aggregateCallback->getHandleCommands),
  )
  handleQueueEvent(makeQueueRef(queueUrl), commandTopicCallback->getHandleJsonCommands)
}

let buildCommandGeneratorHandler = (specModule, _behaviorModule, queueUrl) => {
  let resolvedQueue = makeQueueRef(queueUrl)
  let publishJsons = sqsPublishJsons(resolvedQueue, "SQS_FIFO")
  let generateCommand = makeGenerateCommand(
    publishJsons,
    specModule->getName,
    specModule->getCommandSchema,
    None,
  )
  (event, _context) => generateCommand(event)
}

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

// Opaque handler types to satisfy the value restriction on initPromise
type cmdTopicHandler
type cmdGenHandler

let buildAllHandlers = async (): (dict<cmdTopicHandler>, dict<cmdGenHandler>) => {
  let configStr = env->Dict.get("HANDLER_CONFIG")->Option.getOr(`{"handlers":[]}`)
  let config: config = configStr->JSON.parseOrThrow->Obj.magic

  let cmdTopicHandlers: dict<cmdTopicHandler> = Dict.make()
  let cmdGenHandlers: dict<cmdGenHandler> = Dict.make()

  let _ = await config.handlers
    ->Array.map(async h => {
      let specModule = await dynamicImport(h.specModule)
      let behaviorModule = await dynamicImport(h.behaviorModule)

      cmdTopicHandlers->Dict.set(
        h.queueArn,
        Obj.magic(
          buildCommandTopicHandler(specModule, behaviorModule, h.eventLogTable, h.queueUrl),
        ),
      )

      cmdGenHandlers->Dict.set(
        specModule->getName,
        Obj.magic(buildCommandGeneratorHandler(specModule, behaviorModule, h.queueUrl)),
      )
    })
    ->Promise.all

  (cmdTopicHandlers, cmdGenHandlers)
}

let initPromise = buildAllHandlers()

// === Exported handler ===

let handler = async (event, context) => {
  let (cmdTopicHandlers, cmdGenHandlers) = await initPromise

  // Route 1: AppSync direct invocation (CommandGenerator)
  switch (event->getCommand->Nullable.toOption, event->getArguments->Nullable.toOption) {
  | (Some(_), Some(_)) =>
    let entries = cmdGenHandlers->Dict.toArray
    let len = entries->Array.length
    let i = ref(0)
    let result = ref("")
    let found = ref(false)
    while i.contents < len && !found.contents {
      let (aggName, cmdGenHandler) = entries->Array.getUnsafe(i.contents)
      try {
        let r = await runEffect(None, callHandler(cmdGenHandler, event, context))
        Console.log(`----- commandGeneratorHandler: processed command via ${aggName}`)
        result := Obj.magic(r)
        found := true
      } catch {
      | _ => i := i.contents + 1
      }
    }
    if !found.contents {
      Console.warn(`commandGeneratorHandler: no handler matched command`)
    }
    result.contents

  // Route 2: SQS CommandTopic events
  | _ =>
    let records = event->getRecords->Nullable.toOption->Option.getOr([])
    let correlationId = extractCorrelationId(records)
    let grouped = groupBySource(records)

    let _ = await grouped
      ->Dict.toArray
      ->Array.map(async entry => {
        let (arn, subRecords) = entry
        switch cmdTopicHandlers->Dict.get(arn) {
        | Some(cmdHandler) =>
          Console.log(`----- aggregateHandler: found handler for CommandTopic ${arn}`)
          let _ = await runEffect(
            correlationId,
            callHandler(cmdHandler, mkSubEvent(subRecords), context),
          )
        | None => Console.warn(`aggregateHandler: no handler found: ${arn}`)
        }
      })
      ->Promise.all

    ""
  }
}
