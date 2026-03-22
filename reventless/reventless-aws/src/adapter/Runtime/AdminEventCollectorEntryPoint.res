// Compiled entry point for Admin EventCollector Lambda handler.
// Replaces AdminEventCollectorHandlerFactory.mjs + generated entry point code.
// Lives in the Lambda Layer; imported by a static one-line re-export in the code asset.
// All imports are framework packages — no user modules needed.
//
// Handles outgoing events from plugins via the PluginExtensionPoint EventTopic.
// Wires ExtensionPoint_Operations.Make for outgoing event handling, including
// API schema stitching on connect/disconnect events.

// === Process environment ===
@scope("process") @val external env: dict<string> = "env"

// === Build-verified imports ===

@module("@reventlessdev/reventless-core/src/admin/PluginExtensionPoint_Plugin.res.mjs")
external pluginEPPluginMake: 'a => 'b = "Make"

@module("@reventlessdev/reventless-infra/src/types/PluginExtensionPointSpec.res.mjs")
external pluginExtensionPointSpec: 'a = "default"

@module(
  "@reventlessdev/reventless-core/src/components/ExtensionPoint/ExtensionPoint_Operations.res.mjs"
)
external extensionPointOperationsMake: 'a => 'b => 'c => 'd = "Make"

@module(
  "@reventlessdev/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_SQS_Runtime.res.mjs"
)
external handleDynamoDbOrSqsEvent: ('a, 'b) => 'c = "handleDynamoDbOrSqsEvent"

@module("@reventlessdev/reventless-aws/src/util/Util_SNS_Runtime.res.mjs")
external snsPublish: ('a, 'b, 'c, 'd) => promise<unit> = "publish"

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

@module("@reventlessdev/reventless-core/src/components/Api/GraphQL_Stitcher.res.mjs")
external graphqlStitch: ('a, array<'b>) => string = "stitch"

@module("@reventlessdev/reventless-core/src/components/Api/GraphQL_Stitcher.res.mjs")
external decodeFragment: 'a => 'b = "decode"

@module("@reventlessdev/reventless-core/src/admin/AdminApi.res.mjs")
external adminBaseFragment: bool => 'a = "baseFragment"

@module("@reventlessdev/reventless-core/src/admin/PluginReadModelSpec.res.mjs")
external pluginReadModelStateSchema: 'a = "stateSchema"

@module("sury/src/S.res.mjs")
external suryParseOrThrow: ('a, 'b) => 'c = "parseOrThrow"

// === Helpers ===

@module("./HandlerFactoryHelpers.res.mjs")
external patchSpecId: 'a => 'b = "patchSpecId"

@module("./HandlerFactoryHelpers.res.mjs")
external makeQueueRef: string => 'a = "makeQueueRef"

@module("./HandlerFactoryHelpers.res.mjs")
external scanByTableName: (string, 'a, int) => promise<array<'b>> = "scanByTableName"

// === Effect/Stream ===

@module("effect/Effect")
external effectFlatMap: ('a, 'b => 'c) => 'd = "flatMap"

@module("effect/Effect")
external effectLogInfo: string => 'a = "logInfo"

@module("effect/Effect")
external effectPromise: (unit => promise<'a>) => 'b = "promise"

@module("effect/Effect")
external effectProvideService: ('a, 'b) => 'c = "provideService"

@module("effect/Effect")
external effectRunPromise: 'a = "runPromise"

@module("effect/Stream")
external streamMapEffect: ('a, 'b => 'c) => 'd = "mapEffect"

@module("effect/Stream")
external streamRunDrain: 'a => 'b = "runDrain"

@send external pipe: ('a, 'b) => 'c = "pipe"

// === RequestContext ===

@module("@reventlessdev/reventless-core/src/RequestContext.res.mjs")
external requestContextTag: 'a = "tag"

// === Lambda event accessors ===

@get external getRecords: 'a => Nullable.t<array<'b>> = "Records"
@get external getOutgoingJsonEventsHandler: 'a => 'b = "outgoingJsonEventsHandler"

// === Object constructors ===

let mkRuntimeOps: 'a => 'b = %raw(`
  (sendMessageFn) => ({
    messagePublish: { sendMessageToChannel: sendMessageFn },
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

let mkEpOpsArg: ('a, array<'b>, 'c, 'd, 'e) => 'f = %raw(`
  (publishToEventTopic, commandTopicResources, scheduler, queryEngine, resourceNaming) => ({
    publishToEventTopic,
    commandTopicResources,
    scheduler,
    queryEngine,
    resourceNaming,
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

// Inline @aws_auth injection (same as AppSync_Adapter.injectAwsAuthAll)
let injectAwsAuthAll: ('a, string) => 'b = %raw(`
  function(fragment, group) {
    var parts = decodeFragment(fragment);
    var augmentedMutations = parts.mutations.map(
      (field) => field + "\n    @aws_auth(cognito_groups: [\"" + group + "\"])"
    );
    var augmentedQueries = parts.queries.map(
      (field) => field + " @aws_auth(cognito_groups: [\"" + group + "\"])"
    );
    var encoded = JSON.stringify({
      types: parts.types,
      mutations: augmentedMutations,
      queries: augmentedQueries,
    });
    return { encoded: encoded, protocol: "graphql" };
  }
`)

let mkFakePluginDefinition: unit => 'a = %raw(`() => ({
  id: "Admin@INTERNAL",
  name: "Admin",
  version: "INTERNAL",
  extensionPoints: [],
  extensions: [],
  eventCollector: "NOT-SET",
  extensionProtocols: [],
  apiSchemaFragment: undefined,
})`)

// AWS SDK AppSync - dynamically imported to avoid bundling
let updateAppSyncSchema: (string, string) => promise<unit> = %raw(`
  async function(apiId, sdl) {
    var { AppSyncClient, StartSchemaCreationCommand } = await import("@aws-sdk/client-appsync");
    var client = new AppSyncClient({});
    await client.send(new StartSchemaCreationCommand({ apiId, definition: sdl }));
  }
`)

// === Config types ===

type handlerConfig = {
  queueUrl: string,
  eventTopicArn: string,
  pluginReadModelTableName: string,
  schedulerRoleArn: string,
  schedulerQueueArn: string,
  schedulerQueueName: string,
  appSyncApiId: string,
  clonerEnabled: bool,
}

// === Routing helpers ===

let runEffect = (correlationId, effect) =>
  effect
  ->pipe(effectProvideService(requestContextTag, mkCtx(correlationId)))
  ->pipe(effectRunPromise)

// === Initialization ===

type sqsHandler

let buildHandler = (): sqsHandler => {
  let configStr = env->Dict.get("HANDLER_CONFIG")->Option.getOr(`{}`)
  let config: handlerConfig = configStr->JSON.parseOrThrow->Obj.magic

  let runtimeOps = mkRuntimeOps(sendMessage)
  let lambdaFunctionName = env->Dict.get("AWS_LAMBDA_FUNCTION_NAME")->Option.getOr("unknown")

  // Build updateApiSchema function
  let mkUpdateApiSchema: (string, string, bool) => 'a = %raw(`
    (tableName, apiId, clonerEnabled) => {
      if (!apiId || apiId === "NOT_AVAILABLE") return undefined;
      return async (queryEngine) => {
        var plugins = queryEngine.scan(
          "Plugin",
          [["status", { TAG: "Contains" }, { TAG: "String", _0: "Connected" }]],
          1000
        );
        var resolved = await plugins;
        var fragments = resolved
          .map((json) => {
            try {
              var state = suryParseOrThrow(json, pluginReadModelStateSchema);
              return state.apiSchemaFragment;
            } catch (e) { return undefined; }
          })
          .filter(Boolean);
        var adminBase = injectAwsAuthAll(
          adminBaseFragment(clonerEnabled || false),
          "Admin"
        );
        var sdl = graphqlStitch(adminBase, fragments);
        await updateAppSyncSchema(apiId, sdl);
      };
    }
  `)

  let updateApiSchemaFn = mkUpdateApiSchema(
    config.pluginReadModelTableName,
    config.appSyncApiId,
    config.clonerEnabled,
  )

  let pluginModule = pluginEPPluginMake(mkPluginConfig(runtimeOps, lambdaFunctionName, updateApiSchemaFn))
  let mappingsModule: {"mappings": array<'a>} = {"mappings": [(pluginModule->Obj.magic: {"Mapping": 'a})["Mapping"]]}

  // Reconstruct SNS publish
  let resolvedTopic: {"name": string, "id": string, "arn": string} = {
    "name": config.eventTopicArn,
    "id": config.eventTopicArn,
    "arn": config.eventTopicArn,
  }
  let publishToEventTopic = (id, meta, json) => snsPublish(resolvedTopic, id, meta, json)

  // Reconstruct queryEngine
  let mkQueryEngine: string => 'a = %raw(`
    (tableName) => ({
      scan: (readModelName, filterConfigs, limit) => scanByTableName(tableName, filterConfigs, limit),
      query: async () => { throw new Error("QueryEngine.query not available in bundled Admin EventCollector"); },
    })
  `)
  let queryEngine = mkQueryEngine(config.pluginReadModelTableName)

  // Reconstruct scheduler
  let fakeRole = shimVal(config.schedulerRoleArn)
  let scheduler: {"createSchedule": 'a, "deleteSchedule": 'b} = {
    "createSchedule": cwCreateSchedule({"arn": fakeRole}),
    "deleteSchedule": cwDeleteSchedule,
  }

  let commandTopicResources = if config.schedulerQueueArn != "" {
    [shimResource(config.schedulerQueueName, config.schedulerQueueArn)]
  } else {
    []
  }

  let patchedSpec = patchSpecId(pluginExtensionPointSpec)
  let epOps = extensionPointOperationsMake(patchedSpec)(mappingsModule)(
    mkEpOpsArg(
      publishToEventTopic,
      commandTopicResources,
      scheduler,
      queryEngine,
      mkResourceNaming(),
    ),
  )

  let fakePluginDefinition = mkFakePluginDefinition()

  let handleJsonEvents: 'a => 'b = stream =>
    streamRunDrain(
      streamMapEffect(stream, eventJson =>
        effectFlatMap(
          effectLogInfo(
            `Admin handleJsonEvents: outgoing event: ${(eventJson->JSON.stringify)->String.substring(~start=0, ~end=200)}`,
          ),
          _ =>
            effectPromise(async () => {
              await (epOps->getOutgoingJsonEventsHandler)(eventJson, fakePluginDefinition)->Obj.magic
            }),
        ),
      ),
    )

  Obj.magic(handleDynamoDbOrSqsEvent(makeQueueRef(config.queueUrl), handleJsonEvents))
}

let sqsHandler = buildHandler()

// === Exported handler ===

let handler = async (event, context) => {
  let records = event->getRecords->Nullable.toOption->Option.getOr([])
  Console.log(`----- adminEventCollectorHandler: processing ${records->Array.length->Int.toString} record(s)`)
  let _ = await runEffect(None, callHandler(sqsHandler, event, context))
  ""
}
