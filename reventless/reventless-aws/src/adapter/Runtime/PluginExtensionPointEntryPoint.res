// Compiled entry point for PluginExtensionPoint Lambda handler.
// Replaces PluginExtensionPointHandlerFactory.mjs + generated entry point code.
// Lives in the Lambda Layer; imported by a static one-line re-export in the code asset.
// All imports are framework packages — no user modules needed.

// === Process environment ===
@scope("process") @val external env: dict<string> = "env"

// === Build-verified imports ===

@module("@reventlessdev/reventless-core/src/admin/PluginExtensionPoint_Plugin.res.mjs")
external pluginEPPluginMake: 'a => 'b = "Make"

@module("@reventlessdev/reventless-infra/src/types/PluginExtensionPointSpec.res.mjs")
external pluginExtensionPointSpec: 'a = "default"

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

@module("@reventlessdev/reventless-aws/src/util/Util_PluginMessage_Runtime.res.mjs")
external sendMessage: 'a = "sendMessage"

@module(
  "@reventlessdev/reventless-aws/src/adapter/ScheduledPublisher/ScheduledPublisher_CloudWatchEvents_Runtime.res.mjs"
)
external cwCreateSchedule: 'a => 'b = "createSchedule"

@module(
  "@reventlessdev/reventless-aws/src/adapter/ScheduledPublisher/ScheduledPublisher_CloudWatchEvents_Runtime.res.mjs"
)
external cwDeleteSchedule: 'a = "deleteSchedule"

@module("@reventlessdev/reventless-aws/src/util/Util_PulumiShim.res.mjs")
external shimVal: 'a => 'b = "val"

@module("@reventlessdev/reventless-aws/src/util/Util_PulumiShim.res.mjs")
external shimResource: (string, string) => 'a = "resource"

// === Helpers ===

@module("./HandlerFactoryHelpers.res.mjs")
external patchSpecId: 'a => 'b = "patchSpecId"

@module("./HandlerFactoryHelpers.res.mjs")
external makeQueueRef: string => 'a = "makeQueueRef"

@module("./HandlerFactoryHelpers.res.mjs")
external scanByTableName: (string, 'a, int) => promise<array<'b>> = "scanByTableName"

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
@get external getHandleIncomingCommands: 'a => 'b = "handleIncomingCommands"
@get external getHandleJsonCommands: 'a => 'b = "handleJsonCommands"

// === Object constructors ===

let mkRuntimeOps: 'a => 'b = %raw(`
  (sendMessageFn) => ({
    messagePublish: {
      sendMessageToChannel: sendMessageFn,
    },
    topicSubscription: {
      subscribeChannelToTopic: async () => {},
      unsubscribeChannelFromTopic: async () => {},
    },
  })
`)

let mkPluginConfig: ('a, string, 'b) => 'c = %raw(`
  (runtimeOps, environment, updateApiSchema) => ({
    runtimeOps,
    environment,
    updateApiSchema,
  })
`)

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

let mkCtx: option<string> => 'a = %raw(`(cid) => ({correlationId: cid || "unknown"})`)
let callHandler: ('a, 'b, 'c) => 'd = %raw(`(h, e, c) => h(e, c)`)

let mkResourceNaming: unit => 'a = %raw(`() => {
  var invalidNameChars = /[^.\-_a-zA-Z0-9]/g;
  return {
    validateName: (n) => n.replace(invalidNameChars, "_"),
    urnName: (arn) => { var parts = arn.split(":"); return parts[5] || "unknown"; },
  };
}`)

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

// === Config types ===

type handlerConfig = {
  queueUrl: string,
  pluginReadModelTableName: string,
  schedulerRoleArn: string,
  schedulerQueueArn: string,
  schedulerQueueName: string,
  publishToAggregates: dict<string>,
}

// === Initialization ===

type sqsHandler

let buildHandler = (): sqsHandler => {
  let configStr = env->Dict.get("HANDLER_CONFIG")->Option.getOr(`{}`)
  let config: handlerConfig = configStr->JSON.parseOrThrow->Obj.magic

  let patchedSpec = patchSpecId(pluginExtensionPointSpec)

  // Reconstruct runtimeOps
  let runtimeOps = mkRuntimeOps(sendMessage)

  // Instantiate Plugin EP mapping
  let lambdaFunctionName = env->Dict.get("AWS_LAMBDA_FUNCTION_NAME")->Option.getOr("unknown")
  let pluginModule = pluginEPPluginMake(mkPluginConfig(runtimeOps, lambdaFunctionName, None))
  let mappingsModule: {"mappings": array<'a>} = {"mappings": [(pluginModule->Obj.magic: {"Mapping": 'a})["Mapping"]]}

  // Reconstruct publishToAggregates
  let publishToAggregates: dict<'a> = Dict.make()
  config.publishToAggregates->Dict.forEachWithKey((envVarName, aggName) => {
    let queueUrl = env->Dict.get(envVarName)->Option.getOr("")
    publishToAggregates->Dict.set(aggName, sqsPublishJsons(makeQueueRef(queueUrl), "SQS_FIFO"))
  })

  // Reconstruct queryEngine
  let mkQueryEngine: (string) => 'a = %raw(`
    (tableName) => ({
      scan: (readModelName, filterConfigs, limit) => scanByTableName(tableName, filterConfigs, limit),
      query: async () => { throw new Error("QueryEngine.query not available in bundled Plugin EP handler"); },
    })
  `)
  let queryEngine = mkQueryEngine(config.pluginReadModelTableName)

  // Reconstruct scheduler
  let fakeRole = shimVal(config.schedulerRoleArn)
  let scheduler: {"createSchedule": 'a, "deleteSchedule": 'b} = {
    "createSchedule": cwCreateSchedule({"arn": fakeRole}),
    "deleteSchedule": cwDeleteSchedule,
  }

  // CommandTopic resources for scheduler targets
  let commandTopicResources = if config.schedulerQueueArn != "" {
    [shimResource(config.schedulerQueueName, config.schedulerQueueArn)]
  } else {
    []
  }

  let callbackConfig = mkCallbackConfig(
    publishToAggregates,
    commandTopicResources,
    scheduler,
    queryEngine,
    mkResourceNaming(),
  )

  let callback = extensionPointCallbackMake(callbackConfig)(patchedSpec)(mappingsModule)

  let commandTopicCallback = commandTopicCallbackMake(patchedSpec)(
    mkCmdTopicCallbackArg(patchedSpec, callback->getHandleIncomingCommands),
  )

  Obj.magic(handleQueueEvent(makeQueueRef(config.queueUrl), commandTopicCallback->getHandleJsonCommands))
}

let sqsHandler = buildHandler()

// === Exported handler ===

let handler = async (event, context) => {
  let records = event->getRecords->Nullable.toOption->Option.getOr([])
  let correlationId = extractCorrelationId(records)

  Console.log(`----- pluginExtensionPointHandler: processing ${records->Array.length->Int.toString} record(s)`)
  let _ = await runEffect(correlationId, callHandler(sqsHandler, event, context))
  ""
}
