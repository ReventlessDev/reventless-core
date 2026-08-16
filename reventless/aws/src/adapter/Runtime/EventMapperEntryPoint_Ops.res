// Typed cold-start core for the EventMapper Lambda entry point (Micro mode).
//
// The "typed core, thin shell" split (docs/plans/done/minimize-lambda-entrypoint-mjs-shell.md):
// EventMapperEntryPoint.mjs keeps only the untyped seam — the dynamic
// `import()` of the target-spec/mappings modules named in HANDLER_CONFIG, the
// `patchSpecId` / mapping-Source-Id fix-ups, and the
// EventMapper_Callback.MakeCounterHandler functor application consuming them.
// HANDLER_CONFIG parsing, the publish/query operations, the
// MakeEventCollectorHandler application (a functor over an inline module
// capturing runtime values), and the per-source dispatch boundary live here,
// fully type-checked.
//
// The former shell's queryEngine stub carried wrong field names
// (`query`/`get` for QueryEngine.operations' `scan`/`query`) — a mapping
// calling `scan` crashed with "not a function" instead of the intended
// logged-error fallback. The typed record fixes the shape; both operations
// still log an error and return [] (not available in the bundled handler).

// ── HANDLER_CONFIG ──────────────────────────────────────────────────────────
// Written by AggregateRuntime_Builder_Micro / _Micro_Async.

type handlerConfig = {
  targetSpecModule?: string,
  mappingsModule?: string,
  queueUrl?: string,
}
@val @scope("JSON") external jsonParse: string => handlerConfig = "parse"
// A real binding (not a bare external) so the shell can import it.
let parseHandlerConfig = (raw: string): handlerConfig => jsonParse(raw)

// ── Counter-handler operations (third argument of MakeCounterHandler) ───────

type counterOps = {
  publishJsons: ReventlessCore.CommandTopic.publishJsons,
  queryEngine: Reventless.QueryEngine.operations,
}

let makeCounterOps = (config: handlerConfig): counterOps => {
  let queueUrl = config.queueUrl->Option.getOr("")
  let queue: Util_SQS_Runtime.resolvedQueue = {id: queueUrl, name: queueUrl, arn: ""}
  {
    publishJsons: queue->CommandTopicChannel_SQS_Runtime.publishJsons(AWS.SQS_FIFO),
    queryEngine: {
      scan: async (~readModelName as _, ~filterConfigs as _, ~limit as _) => {
        StreamRoutedEntryPoint_Ops.logError(
          "queryEngine not available in bundled mode",
          {comp: "EventMapperEntryPoint"},
        )
        []
      },
      query: async (
        ~readModelName as _,
        ~key as _=?,
        ~id as _,
        ~subIdConfig as _=?,
        ~filterConfigs as _=?,
        ~ascending as _=?,
        ~limit as _=?,
      ) => {
        StreamRoutedEntryPoint_Ops.logError(
          "queryEngine not available in bundled mode",
          {comp: "EventMapperEntryPoint"},
        )
        []
      },
    },
  }
}

// ── Stream handler ──────────────────────────────────────────────────────────
// `commonEventsHandler` comes off the shell's MakeCounterHandler application
// (it consumes the runtime-loaded target/mappings modules); everything it
// feeds — counter no-ops, publishing, the stream wrap — is typed.

type commonEventsHandler = array<JSON.t> => promise<(
  promise<array<ReventlessCore.Message.commandJson>>,
  array<ReventlessCore.Counter.action>,
)>

let makeStreamHandler = (
  ops: counterOps,
  commonEventsHandler: commonEventsHandler,
): StreamRoutedEntryPoint_Ops.streamHandler => {
  module Handler = ReventlessCore.EventMapper_Callback.MakeEventCollectorHandler({
    let publishJsons = ops.publishJsons
    let count: ReventlessCore.Counter.count = async _ => ()
    let addToCounterTarget: ReventlessCore.Counter.addToCounterTarget = async _ => ()
    let commonEventsHandler = commonEventsHandler
  })
  StreamRoutedEntryPoint_Ops.toStreamHandler(Handler.handleJsonEvents)
}

// ── Dispatch boundary ───────────────────────────────────────────────────────
// Unlike the registry-routed entry points (one Lambda, many components), the
// mapper Lambda serves a single target: every source group runs the same
// handler, attributed `EventMapper(<Target>)`.

let makeHandler = (
  buildPromise: promise<(StreamRoutedEntryPoint_Ops.streamHandler, string)>,
) =>
  async (event: PulumiAws.Lambda.CallbackFunction.event, context: PulumiAws.Lambda.context) => {
    StreamRoutedEntryPoint_Ops.setRequestId(context.awsRequestId)
    let (streamHandler, comp) = await buildPromise
    let _ =
      await StreamRoutedEntryPoint_Ops.groupBySource(event.records)
      ->Dict.toArray
      ->Array.map(async ((arn, subRecords)) => {
        StreamRoutedEntryPoint_Ops.logDebug("processing " ++ arn, {comp: "EventMapperRuntime"})
        let subEvent: PulumiAws.Lambda.CallbackFunction.event = {records: subRecords}
        await StreamRoutedEntryPoint_Ops.runEffect(
          streamHandler(subEvent, context),
          {
            correlationId: ?StreamRoutedEntryPoint_Ops.extractMetaField(
              subRecords,
              "correlationId",
            ),
            causationId: ?StreamRoutedEntryPoint_Ops.extractMetaField(subRecords, "causationId"),
            comp,
            timestamp: ?StreamRoutedEntryPoint_Ops.extractSentTimestamp(subRecords),
            retryCount: StreamRoutedEntryPoint_Ops.extractRetryCount(subRecords),
          },
        )
      })
      ->Promise.all
    ""
  }
