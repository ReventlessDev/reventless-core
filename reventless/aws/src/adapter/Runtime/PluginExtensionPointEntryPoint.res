// PluginExtensionPoint Lambda entry point — compiled, type-checked ReScript
// (replaces the hand-written PluginExtensionPointEntryPoint.mjs shell).
//
// All wiring is framework modules — no user modules, hence no dynamic-import
// seam and no reason to stay untyped. Handles Heartbeat, Cloner, and other
// plugin-level extension point commands.
//
// The former shell's `patchSpecId` hack (re-adding the `Id` module that the
// ESM export of a `module Id = …` alias drops) disappears: `SpecWithId` below
// binds the Id module at the ReScript level, mirroring ExtensionPoint_Builder.
// Runtime-pure: no Pulumi value reaches this module's import graph.

@val @scope("process") external processEnv: dict<string> = "env"

// ── Shim bindings (HandlerFactoryHelpers.mjs) ───────────────────────────────
// The structured-log + Effect dispatch boundary shared by every deployed entry
// point (single place where invocations get their log annotations and
// RequestContext), and the DynamoDB scan backing the read-model query engine.

// Extra fields threaded onto the dispatch boundary / log lines. The shim reads
// them structurally, so one record serves both `runEffect` and `log.debug`.
type dispatchOpts = {
  correlationId?: string,
  causationId?: string,
  comp?: string,
  timestamp?: float,
  retryCount?: int,
}

@module("./HandlerFactoryHelpers.mjs")
external setRequestId: string => unit = "setRequestId"
@module("./HandlerFactoryHelpers.mjs")
external runEffect: (Effect.t<'a, 'e, 'r>, dispatchOpts) => promise<unit> = "runEffect"
@module("./HandlerFactoryHelpers.mjs")
external extractMetaField: (array<PulumiAws.SQS.Queue.record>, string) => option<string> =
  "extractMetaField"
@module("./HandlerFactoryHelpers.mjs")
external extractSentTimestamp: array<PulumiAws.SQS.Queue.record> => option<float> =
  "extractSentTimestamp"
@module("./HandlerFactoryHelpers.mjs")
external extractRetryCount: array<PulumiAws.SQS.Queue.record> => int = "extractRetryCount"
@module("./HandlerFactoryHelpers.mjs") @scope("log")
external logDebug: (string, dispatchOpts) => unit = "debug"
@module("./HandlerFactoryHelpers.mjs")
external scanByTableName: (
  string,
  array<Reventless.QueryEngine.Filter.config>,
  int,
) => promise<array<JSON.t>> = "scanByTableName"

// ── HANDLER_CONFIG ──────────────────────────────────────────────────────────
// Written by PluginExtensionPointRuntime_Builder.forCommandTopic; all fields
// optional so a partial config degrades like the former shell's `|| ""` reads.

type handlerConfig = {
  queueUrl?: string,
  pluginReadModelTableName?: string,
  schedulerRoleArn?: string,
  schedulerQueueArn?: string,
  schedulerQueueName?: string,
  publishToAggregates?: dict<string>,
}
@val @scope("JSON") external parseHandlerConfig: string => handlerConfig = "parse"

// === Initialize eagerly at module load (Lambda cold start) ===

let config = processEnv->Dict.get("HANDLER_CONFIG")->Option.getOr("{}")->parseHandlerConfig

// Instantiate the Plugin EP mapping. updateApiSchema and manageSubscriptions
// are admin-only hooks; this Lambda only handles incoming commands (Heartbeat,
// ForwardCommand) so they stay None here. Only sendMessageToChannel is used by
// the incoming-command path (ForwardCommand) — cross-plugin subscribe /
// unsubscribe directives were retired in Phase 3 Step 3.
//
// `environment` prefixes the disconnect schedule's EventBridge rule name, so it
// must be stable across deploys and unique per stack. The stack name is both;
// AWS_LAMBDA_FUNCTION_NAME is neither — it carries a content hash, so replacing
// this Lambda would orphan every outstanding rule the previous generation
// created. EventCollectorEntryPoint instantiates the same EP module and must
// agree, or one Lambda creates rules the other cannot delete.
module EpSpec = {
  let runtimeOps: ReventlessCore.PluginRuntimeOperations.operations = {
    messagePublish: {sendMessageToChannel: Util_PluginMessage_Runtime.sendMessage},
  }
  let environment = processEnv->Dict.get("Environment")->Option.getOr("unknown")
  let updateApiSchema: option<Reventless.QueryEngine.operations => promise<unit>> = None
  let manageSubscriptions: option<
    (Reventless.Plugin.pluginDefinition, [#connect | #disconnect]) => promise<unit>,
  > = None
}
module PluginMappingInstance = ReventlessCore.PluginExtensionPoint_Plugin.Make(EpSpec)

module Mappings = {
  module type Mapping = ReventlessInfra.ExtensionPointMapping.T
    with module ExtensionPoint := ReventlessInfra.PluginExtensionPointSpec
  // Parity with the former shell: only the Plugin lifecycle mapping. The
  // in-process wiring (PluginExtensionPoint_Builder) additionally registers
  // PluginExtensionPoint_UiFragment.Mapping — divergence tracked in
  // docs/plans/entry-point-rescript-conversion.md.
  let mappings: array<module(Mapping)> = [module(PluginMappingInstance.Mapping)]
}

// Reconstruct publishToAggregates. The deploy-side builder writes
// HANDLER_CONFIG.publishToAggregates as { aggregateName: envVarName }
// (see PluginExtensionPointRuntime_Builder.res), so iterate accordingly.
let publishToAggregates: dict<ReventlessCore.CommandTopic.publishJsons> =
  config.publishToAggregates
  ->Option.getOr(Dict.make())
  ->Dict.toArray
  ->Array.map(((aggName, envVarName)) => {
    let queueUrl = processEnv->Dict.get(envVarName)->Option.getOr("")
    let queue: Util_SQS_Runtime.resolvedQueue = {id: queueUrl, name: queueUrl, arn: ""}
    (aggName, queue->CommandTopicChannel_SQS_Runtime.publishJsons(AWS.SQS_FIFO))
  })
  ->Dict.fromArray

// Reconstruct queryEngine: scans go to the plugin read-model table; query is
// not available in this bundled handler (same restriction as the former shell).
let pluginReadModelTableName = config.pluginReadModelTableName->Option.getOr("")
let queryEngine: Reventless.QueryEngine.operations = {
  scan: (~readModelName as _, ~filterConfigs, ~limit) =>
    scanByTableName(pluginReadModelTableName, filterConfigs, limit),
  query: async (
    ~readModelName as _,
    ~key as _=?,
    ~id as _,
    ~subIdConfig as _=?,
    ~filterConfigs as _=?,
    ~ascending as _=?,
    ~limit as _=?,
  ) => JsError.throwWithMessage("QueryEngine.query not available in bundled Plugin EP handler"),
}

// Reconstruct scheduler
let scheduler: ReventlessCore.Scheduler.operations = {
  createSchedule: ScheduledPublisher_CloudWatchEvents_Runtime.createSchedule(
    ~roleArn=config.schedulerRoleArn->Option.getOr(""),
  ),
  deleteSchedule: ScheduledPublisher_CloudWatchEvents_Runtime.deleteSchedule,
}

// CommandTopic resources for scheduler targets
let commandTopicResources: array<ReventlessInfra.Adapter.resolvedResource> = {
  let schedulerQueueArn = config.schedulerQueueArn->Option.getOr("")
  let schedulerQueueName = config.schedulerQueueName->Option.getOr("")
  schedulerQueueArn == ""
    ? []
    : [
        {
          name: schedulerQueueName,
          id: schedulerQueueName,
          urn: schedulerQueueArn,
          service: "unknown",
          resourceInfo: ReventlessInfra.Adapter.NoInfo,
          role: "",
          region: "",
          resourceType: "",
          configuration: Dict.make(),
          tags: Dict.make(),
        },
      ]
}

let invalidNameChars = %re("/[^.\-_a-zA-Z0-9]/g")
let resourceNaming: ReventlessInfra.ResourceNaming.operations = {
  validateName: n => n->String.replaceRegExp(invalidNameChars, "_"),
  urnName: arn =>
    arn
    ->String.split(":")
    ->Array.get(5)
    ->Option.filter(s => s != "")
    ->Option.getOr("unknown"),
}

module Callback = ReventlessCore.ExtensionPoint_Callback.Make(
  {
    let publishToAggregates = publishToAggregates
    let commandTopicResources = commandTopicResources
    let scheduler = scheduler
    let queryEngine = queryEngine
    let resourceNaming = resourceNaming
  },
  ReventlessInfra.PluginExtensionPointSpec,
  Mappings,
)

module SpecWithId = {
  module Id = Reventless.Id.String
  let name = ReventlessInfra.PluginExtensionPointSpec.name
  type command = ReventlessInfra.PluginExtensionPointSpec.command
  let commandSchema = ReventlessInfra.PluginExtensionPointSpec.commandSchema
}

module CommandTopicCallback = ReventlessCore.CommandTopic_Callback.Make(
  SpecWithId,
  {
    module Spec = SpecWithId
    let commandsHandler = Callback.handleIncomingCommands
  },
)

let queue: Util_SQS_Runtime.resolvedQueue = {
  id: config.queueUrl->Option.getOr(""),
  name: config.queueUrl->Option.getOr(""),
  arn: "",
}
let sqsHandler = CommandTopicChannel_SQS_Runtime.handleQueueEvent(
  queue,
  CommandTopicCallback.handleJsonCommands,
)
let comp = `ExtensionPoint(${ReventlessInfra.PluginExtensionPointSpec.name})`

// === Exported handler ===

let handler = async (event: PulumiAws.SQS.Queue.event, context: PulumiAws.Lambda.context) => {
  setRequestId(context.awsRequestId)
  let records = event.records

  logDebug(
    `processing ${records->Array.length->Int.toString} record(s)`,
    {comp: "PluginExtensionPointRuntime"},
  )
  await runEffect(
    sqsHandler(event, context),
    {
      correlationId: ?extractMetaField(records, "correlationId"),
      causationId: ?extractMetaField(records, "causationId"),
      comp,
      timestamp: ?extractSentTimestamp(records),
      retryCount: extractRetryCount(records),
    },
  )
  ""
}
