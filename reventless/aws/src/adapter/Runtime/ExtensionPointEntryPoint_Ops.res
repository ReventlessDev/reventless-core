// Typed cold-start core for the (per-extension-point) ExtensionPoint Lambda
// entry point.
//
// The "typed core, thin shell" split (docs/plans/minimize-lambda-entrypoint-mjs-shell.md):
// ExtensionPointEntryPoint.mjs keeps only the untyped seam — the dynamic
// `import()` of the spec/mappings modules named in HANDLER_CONFIG, the
// `patchSpecId` fix-up, and the ExtensionPoint_Callback.Make /
// CommandTopic_Callback.Make functor applications consuming them. The callback
// config (publish dict, scheduler/query stubs, resource naming), HANDLER_CONFIG
// parsing, and the SQS dispatch boundary live here, fully type-checked.
//
// The former shell's stub records carried wrong field names (`create`/`delete`
// for Scheduler.operations' `createSchedule`/`deleteSchedule`, `name`/`resolve`
// for ResourceNaming.operations' `validateName`/`urnName`) — a mapping touching
// them crashed with "not a function" instead of the intended error. The typed
// records fix the shapes; scheduler/queryEngine still throw by design (not
// available in the bundled handler).


// ── Shim bindings (HandlerFactoryHelpers.mjs), typed for SQS records ────────
@module("./HandlerFactoryHelpers.mjs")
external setRequestId: string => unit = "setRequestId"
@module("./HandlerFactoryHelpers.mjs")
external runEffect: (
  Effect.t<'a, 'e, 'r>,
  StreamRoutedEntryPoint_Ops.dispatchOpts,
) => promise<unit> = "runEffect"
@module("./HandlerFactoryHelpers.mjs")
external extractMetaField: (array<PulumiAws.SQS.Queue.record>, string) => option<string> =
  "extractMetaField"
@module("./HandlerFactoryHelpers.mjs")
external extractSentTimestamp: array<PulumiAws.SQS.Queue.record> => option<float> =
  "extractSentTimestamp"
@module("./HandlerFactoryHelpers.mjs")
external extractRetryCount: array<PulumiAws.SQS.Queue.record> => int = "extractRetryCount"
@module("./HandlerFactoryHelpers.mjs") @scope("log")
external logDebug: (string, StreamRoutedEntryPoint_Ops.dispatchOpts) => unit = "debug"

// ── HANDLER_CONFIG ──────────────────────────────────────────────────────────
// Written by ExtensionPointRuntime_Builder_PerExtensionPoint; all fields
// optional so a partial config degrades like the former shell's `|| ""` reads.

type handlerConfig = {
  specModule?: string,
  mappingsModule?: string,
  queueUrl?: string,
  // aggregateName → env-var name holding the aggregate's cmd-topic SQS URL.
  publishToAggregates?: dict<string>,
}
@val @scope("JSON") external jsonParse: string => handlerConfig = "parse"
// A real binding (not a bare external) so the shell can import it.
let parseHandlerConfig = (raw: string): handlerConfig => jsonParse(raw)

// ── Callback config (first argument of ExtensionPoint_Callback.Make) ────────
// The record's field names/types mirror ExtensionPoint_Callback's `Spec` module
// type — the compiled functor consumes it as a plain object.

type callbackSpec = {
  publishToAggregates: dict<ReventlessCore.CommandTopic.publishJsons>,
  commandTopicResources: array<ReventlessInfra.Adapter.resolvedResource>,
  scheduler: ReventlessCore.Scheduler.operations,
  queryEngine: Reventless.QueryEngine.operations,
  resourceNaming: ReventlessInfra.ResourceNaming.operations,
}

let makeCallbackSpec = (config: handlerConfig): callbackSpec => {
  publishToAggregates: config.publishToAggregates
  ->Option.getOr(Dict.make())
  ->Dict.toArray
  ->Array.map(((aggName, envVarName)) => {
    let queueUrl = NodeProcess.env->Dict.get(envVarName)->Option.getOr("")
    let queue: Util_SQS_Runtime.resolvedQueue = {id: queueUrl, name: queueUrl, arn: ""}
    (aggName, queue->CommandTopicChannel_SQS_Runtime.publishJsons(AWS.SQS_FIFO))
  })
  ->Dict.fromArray,
  commandTopicResources: [],
  scheduler: {
    createSchedule: (_, _) =>
      JsError.throwWithMessage("Scheduler not available in bundled ExtensionPoint handler"),
    deleteSchedule: (_, _) =>
      JsError.throwWithMessage("Scheduler not available in bundled ExtensionPoint handler"),
  },
  queryEngine: {
    scan: (~readModelName as _, ~filterConfigs as _, ~limit as _) =>
      JsError.throwWithMessage("QueryEngine not available in bundled ExtensionPoint handler"),
    query: (
      ~readModelName as _,
      ~key as _=?,
      ~id as _,
      ~subIdConfig as _=?,
      ~filterConfigs as _=?,
      ~ascending as _=?,
      ~limit as _=?,
    ) => JsError.throwWithMessage("QueryEngine not available in bundled ExtensionPoint handler"),
  },
  resourceNaming: {
    validateName: n => n,
    urnName: n => n,
  },
}

// ── SQS dispatch boundary ───────────────────────────────────────────────────
// The shell resolves the spec module, applies the functors, and hands the
// typed jsonCommandsHandler back here; `comp` pairs the invocation's log lines
// with the extension point the Lambda serves, not just the Lambda itself.

type built = {
  comp: string,
  sqsHandler: (
    PulumiAws.SQS.Queue.event,
    PulumiAws.Lambda.context,
  ) => Effect.t<unit, string, unit>,
}

let makeBuilt = (
  config: handlerConfig,
  specName: string,
  handleJsonCommands: ReventlessCore.CommandTopic.jsonCommandsHandler,
): built => {
  let queueUrl = config.queueUrl->Option.getOr("")
  let queue: Util_SQS_Runtime.resolvedQueue = {id: queueUrl, name: queueUrl, arn: ""}
  {
    comp: `ExtensionPoint(${specName})`,
    sqsHandler: CommandTopicChannel_SQS_Runtime.handleQueueEvent(queue, handleJsonCommands),
  }
}

let makeHandler = (buildPromise: promise<built>) =>
  async (event: PulumiAws.SQS.Queue.event, context: PulumiAws.Lambda.context) => {
    setRequestId(context.awsRequestId)
    let {comp, sqsHandler} = await buildPromise
    let records = event.records

    logDebug(
      `processing ${records->Array.length->Int.toString} record(s)`,
      {comp: "ExtensionPointRuntime"},
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
