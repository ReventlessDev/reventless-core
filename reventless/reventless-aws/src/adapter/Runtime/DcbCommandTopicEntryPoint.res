// Compiled entry point for DCB CommandTopic Lambda handlers.
// Replaces DcbCommandTopicHandlerFactory.mjs + generated entry point code.
// Lives in the Lambda Layer; imported by a static one-line re-export in the code asset.
//
// At cold start:
//   1. Reads HANDLER_CONFIG from env vars
//   2. Dynamically imports user StateChangeSlice Spec modules
//   3. Wires StateChangeSlice_Callback.Make(Spec) + DcbEventLog_Operations.Make
//   4. Builds composite command router keyed by command type tag
//   5. Routes SQS events through handleQueueEvent

// === Dynamic import ===
let dynamicImport: string => promise<'a> = %raw(`(specifier) => import('/var/task/node_modules/' + specifier)`)

// === Process environment ===
@scope("process") @val external env: dict<string> = "env"

// === Config types ===

type handlerConfig = {
  dcbEventLogTableName: string,
  queueUrl: string,
  pluginName: string,
  stateChangeSliceModules: array<string>,
}

type config = handlerConfig

// === Build-verified functor imports ===

@module(
  "@reventlessdev/reventless-core/src/components/StateChangeSlice/StateChangeSlice_Callback.res.mjs"
)
external stateChangeSliceCallbackMake: 'a => 'b = "Make"

@module(
  "@reventlessdev/reventless-core/src/components/DcbEventLog/DcbEventLog_Operations.res.mjs"
)
external dcbEventLogOperationsMake: 'a => 'b = "Make"

@module(
  "@reventlessdev/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res.mjs"
)
external dcbRead: 'a => 'b = "read"

@module(
  "@reventlessdev/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res.mjs"
)
external dcbAppend: 'a => 'b = "append"

@module(
  "@reventlessdev/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res.mjs"
)
external dcbReadStream: 'a => 'b = "readStream"

@module(
  "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs"
)
external handleQueueEvent: ('a, 'b) => 'c = "handleQueueEvent"

@module("@reventlessdev/reventless-core/src/Message.res.mjs")
external decodeCommand': ('a, 'b, 'c) => 'd = "decodeCommand$p"

@module(
  "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs"
)
external sqsPublishJsons: ('a, string) => 'b = "publishJsons"

@module("@reventlessdev/reventless-spec/src/types/Id.res.mjs")
external idStringSchema: 'a = "$$String"

@module("@reventlessdev/reventless-spec/src/components/DcbTag.res.mjs")
external extractEventTypes: 'a => array<string> = "extractEventTypes"

// === Helpers ===

@module("./HandlerFactoryHelpers.res.mjs")
external patchSpecId: 'a => 'b = "patchSpecId"

@module("./HandlerFactoryHelpers.res.mjs")
external makeQueueRef: string => 'a = "makeQueueRef"

// === Effect/Stream ===

@module("effect/Effect")
external effectSync: (unit => 'a) => 'b = "sync"

@module("effect/Effect")
external effectSucceed: 'a => 'b = "succeed"

@module("effect/Effect")
external effectProvideService: ('a, 'b) => 'c = "provideService"

@module("effect/Effect")
external effectRunPromise: 'a = "runPromise"

@module("effect/Stream")
external streamMake: 'a => 'b = "make"

@module("effect/Stream")
external streamEmpty: 'a = "empty"

@module("effect/Stream")
external streamMapEffect: ('a, 'b => 'c) => 'd = "mapEffect"

@module("effect/Stream")
external streamFlatMap: ('a, 'b => 'c) => 'd = "flatMap"

@module("effect/Stream")
external streamRunCollect: 'a => 'b = "runCollect"

@send external pipe: ('a, 'b) => 'c = "pipe"

// === RequestContext ===

@module("@reventlessdev/reventless-core/src/RequestContext.res.mjs")
external requestContextTag: 'a = "tag"

// === Lambda event accessors ===

@get external getRecords: 'a => Nullable.t<array<'b>> = "Records"
@get external getBody: 'a => Nullable.t<string> = "body"
@get external getCommand: 'a => Nullable.t<string> = "command"
@get external getArguments: 'a => Nullable.t<'b> = "arguments"

// === Object/field accessors ===

@get external getHandleCommands: 'a => 'b = "handleCommands"
@get external getHandleJsonCommands: 'a => 'b = "handleJsonCommands"
@get external getCommandSchema: 'a => 'b = "commandSchema"

// === TopicItem field accessors ===
// handleQueueEvent wraps each SQS record as {command: JSON.t, reference: string}
@get external getTopicCommand: 'a => 'b = "command"
@get external getTopicReference: 'a => string = "reference"
let mkTopicItem: ('a, string) => 'b = %raw(`(command, reference) => ({command, reference})`)

let mkNameObj: string => 'a = %raw(`(name) => ({name})`)

let mkDcbEventLogOpsArg: (string, 'b, 'c) => 'd = %raw(`
  (name, storage, publishJson) => ({
    name,
    storage,
    publishJson,
  })
`)

let mkStorageOps: ('a, 'b, 'c) => 'd = %raw(`
  (read, append, readStream) => ({read, append, readStream})
`)

let mkCtx: option<string> => 'a = %raw(`(cid) => ({correlationId: cid || "unknown"})`)
let callHandler: ('a, 'b, 'c) => 'd = %raw(`(h, e, c) => h(e, c)`)
let noopPublishJson: unit => 'a = %raw(`() => (async (_name, _meta, _json) => {})`)

// Extract command type tag from JSON
let extractTypeName: 'a => option<string> = %raw(`
  function(json) {
    if (typeof json === 'string') return json;
    if (json && typeof json === 'object') {
      var commandJson = json.commandJson || json;
      if (typeof commandJson === 'string') return commandJson;
      if (commandJson && commandJson.TAG) return commandJson.TAG;
      var keys = Object.keys(commandJson);
      if (keys.length === 1 && keys[0] !== 'id' && keys[0] !== 'meta') return keys[0];
    }
    return undefined;
  }
`)

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

// Get IdString.schema from the imported module
let getIdStringSchema: unit => 'a = %raw(`() => idStringSchema.schema`)

// === Initialization ===

type sqsHandler
type cmdGenHandler

let buildHandler = async (): (sqsHandler, cmdGenHandler) => {
  let configStr = env->Dict.get("HANDLER_CONFIG")->Option.getOr(`{}`)
  let config: config = configStr->JSON.parseOrThrow->Obj.magic

  let resolvedTable = mkNameObj(config.dcbEventLogTableName)
  let rawStorageOps = mkStorageOps(
    dcbRead(resolvedTable),
    dcbAppend(resolvedTable),
    dcbReadStream(resolvedTable),
  )

  // Build handler routing table: commandTypeName → jsonCommandsHandler
  let handlersByType: dict<'a> = Dict.make()

  // Build shared DcbEventLog operations (just storage + name, no Spec needed)
  let sharedDcbEventLogOps = dcbEventLogOperationsMake(
    mkDcbEventLogOpsArg(
      config.pluginName,
      rawStorageOps,
      noopPublishJson(),
    ),
  )

  let _ = await config.stateChangeSliceModules
    ->Array.map(async modPath => {
      let specModule = await dynamicImport(modPath)
      let patchedSpec = patchSpecId(specModule)

      let dcbEventLogOps = sharedDcbEventLogOps

      let sliceCallback = stateChangeSliceCallbackMake(patchedSpec)
      let commandSchema = patchedSpec->getCommandSchema
      let typeNames = extractEventTypes(commandSchema)

      // Build jsonHandler that decodes commands and delegates to sliceCallback.
      // Input stream contains topicItems: {command: JSON.t, reference: string}.
      // Must unwrap .command for decoding, then re-wrap with reference for the
      // downstream handleCommands which expects Stream.t<topicItem<command'>>.
      let jsonHandler: 'a => 'b = stream => {
        let decodedStream = streamFlatMap(
          streamMapEffect(stream, topicItem => {
            effectSync(() => {
              try {
                let decoded = decodeCommand'(
                  topicItem->getTopicCommand,
                  getIdStringSchema(),
                  commandSchema,
                )
                {"TAG": "Some", "_0": mkTopicItem(decoded, topicItem->getTopicReference)}
              } catch {
              | _ => {"TAG": "None", "_0": Obj.magic(0)}
              }
            })
          }),
          opt => {
            if (opt->Obj.magic: {"TAG": string})["TAG"] == "Some" {
              streamMake((opt->Obj.magic: {"_0": 'b})["_0"])
            } else {
              streamEmpty
            }
          },
        )
        (sliceCallback->getHandleCommands)(dcbEventLogOps, decodedStream)
      }

      typeNames->Array.forEach(typeName => {
        handlersByType->Dict.set(typeName, Obj.magic(jsonHandler))
      })
    })
    ->Promise.all

  // Composite handler: routes by message type.
  // Stream contains topicItems: {command: JSON.t, reference: string}.
  // Extract type name from the inner .command JSON, not the wrapper.
  let compositeJsonCommandsHandler: 'a => 'b = stream => {
    streamRunCollect(
      streamMapEffect(stream, topicItem => {
        let typeNameOpt = extractTypeName(topicItem->getTopicCommand)
        switch typeNameOpt {
        | Some(typeName) =>
          switch handlersByType->Dict.get(typeName) {
          | Some(handler) =>
            let singleStream = streamMake(topicItem)
            handler(singleStream)
          | None =>
            Console.warn(`DCB: no handler for command type: ${typeName}`)
            effectSucceed([])
          }
        | None =>
          Console.warn("DCB: could not extract command type")
          effectSucceed([])
        }
      }),
    )
  }

  let resolvedQueue = makeQueueRef(config.queueUrl)
  let sqsHandler = Obj.magic(handleQueueEvent(resolvedQueue, compositeJsonCommandsHandler))

  // Build AppSync command generator: publishes to SQS, returns msgId
  // DCB commands come from multiple slices with different schemas — skip schema validation here.
  // The SQS handler validates each command against its slice's schema.
  // AppSync command generator: builds command JSON from resolver payload, publishes to SQS
  let mkCmdGenHandler: ('a, string) => cmdGenHandler = %raw(`
    function(publishFn, pluginName) {
      return function(payload) {
        var msgId = crypto.randomUUID();
        // DCB commands may not have an 'id' field — use the first argument value as entity ID
        var args = payload.arguments;
        var id = args.id;
        if (!id) {
          // Find the first field ending in 'Id' (e.g., productId, orderId)
          for (var key of Object.keys(args)) {
            if (key.endsWith('Id') && typeof args[key] === 'string') { id = args[key]; break; }
          }
        }
        if (!id) id = msgId; // fallback to message ID
        var ip = payload.meta && payload.meta.ip && Array.isArray(payload.meta.ip) ? payload.meta.ip[0] || "" : "";
        var user = payload.meta && payload.meta.user ? payload.meta.user : "";
        var meta = { service: pluginName, time: new Date().toISOString(), ip: ip, user: user, msgId: msgId, correlationId: msgId };
        var obj = JSON.parse(JSON.stringify(args));
        delete obj.id;
        var params = Object.entries(obj);
        var commandJson = params.length > 0 ? Object.fromEntries([["TAG", payload.command]].concat(params)) : payload.command;
        return publishFn([{id: id, meta: meta, commandJson: commandJson}]).then(function() { return msgId; });
      };
    }
  `)
  let publishJsons = sqsPublishJsons(resolvedQueue, "SQS_FIFO")
  let cmdGenHandler = mkCmdGenHandler(publishJsons, config.pluginName)

  (sqsHandler, cmdGenHandler)
}

let initPromise = buildHandler()

// === Exported handler ===

let handler = async (event, context) => {
  let (sqsHandler, cmdGenHandler) = await initPromise

  // Route 1: AppSync direct invocation (CommandGenerator)
  switch (event->getCommand->Nullable.toOption, event->getArguments->Nullable.toOption) {
  | (Some(_), Some(_)) =>
    Console.log("----- dcbCommandTopicHandler: AppSync direct invocation")
    let result: string = await (Obj.magic(cmdGenHandler): 'a => promise<string>)(event)
    result

  // Route 2: SQS CommandTopic events
  | _ =>
    let records = event->getRecords->Nullable.toOption->Option.getOr([])
    let correlationId = extractCorrelationId(records)

    Console.log(
      `----- dcbCommandTopicHandler: processing ${records->Array.length->Int.toString} record(s)`,
    )
    let _ = await runEffect(correlationId, callHandler(sqsHandler, event, context))
    ""
  }
}
