// Typed routed dispatch boundary shared by the stream-routed Lambda entry
// points (ReadModelEntryPoint.mjs, StateViewSliceEntryPoint.mjs,
// AutomationSliceEntryPoint.mjs).
//
// The "typed core, thin shell" split (docs/plans/minimize-lambda-entrypoint-mjs-shell.md):
// all three shells route DynamoDB-stream / SQS-feed records to per-source-URN
// handler lists with per-handler log attribution — machinery the `.mjs` files
// previously duplicated verbatim. It lives here so every co-hosted component
// dispatches identically; the shells keep only their dynamic-import seams.
//
// Kept free of storage-backend imports (in particular the Postgres runtime,
// which lives in ProjectionEntryPoint_Ops): the AutomationSlice Lambda routes
// through this module but must not carry `pg`/PgRuntime in its cold-start
// graph.
//
// Runtime-pure: no `open PulumiAws` values — Pulumi appears in type positions
// only (erased).

// ── Shim bindings (HandlerFactoryHelpers.mjs) ───────────────────────────────
// The structured-log + Effect dispatch boundary shared by every deployed entry
// point.

type dispatchOpts = {
  correlationId?: string,
  causationId?: string,
  comp?: string,
  plugin?: string,
  timestamp?: float,
  retryCount?: int,
  detail?: string,
}

@module("./HandlerFactoryHelpers.mjs")
external setRequestId: string => unit = "setRequestId"
@module("./HandlerFactoryHelpers.mjs")
external runEffect: (Effect.t<'a, 'e, 'r>, dispatchOpts) => promise<unit> = "runEffect"
@module("./HandlerFactoryHelpers.mjs")
external extractMetaField: (
  array<PulumiAws.Lambda.CallbackFunction.record>,
  string,
) => option<string> = "extractMetaField"
@module("./HandlerFactoryHelpers.mjs")
external extractSentTimestamp: array<PulumiAws.Lambda.CallbackFunction.record> => option<float> =
  "extractSentTimestamp"
@module("./HandlerFactoryHelpers.mjs")
external extractRetryCount: array<PulumiAws.Lambda.CallbackFunction.record> => int =
  "extractRetryCount"
@module("./HandlerFactoryHelpers.mjs") @scope("log")
external logDebug: (string, dispatchOpts) => unit = "debug"
@module("./HandlerFactoryHelpers.mjs") @scope("log")
external logWarn: (string, dispatchOpts) => unit = "warn"
@module("./HandlerFactoryHelpers.mjs") @scope("log")
external logError: (string, dispatchOpts) => unit = "error"

let exnMessage = (exn: exn): string =>
  exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown error")

// ── Handler registry + routed dispatch boundary ─────────────────────────────

type streamHandler = (
  PulumiAws.Lambda.CallbackFunction.event,
  PulumiAws.Lambda.context,
) => Effect.t<unit, string, unit>

// One Lambda hosts every component of its kind, so each handler carries the
// comp of the component it runs (and, for read models, the owning plugin —
// the shared Lambda's own name carries no single plugin identity).
type registeredHandler = {
  handler: streamHandler,
  comp?: string,
  plugin?: string,
}

let toStreamHandler = (
  handleJsonEvents: ReventlessCore.EventCollector.jsonEventsHandler,
): streamHandler =>
  (event, context) =>
    EventCollectorChannel_DynamoDbStream_Runtime.handleStreamEvent(handleJsonEvents, event, context)

// Multiple components can share one source stream — e.g. every admin read
// model (Plugins, PluginHistory, PlatformEventGraph, UIFragmentRegistry)
// projects the Plugin aggregate's EventLog stream, and several automation
// slices can react to the same DcbEventLog. Accumulate ALL handlers per source
// URN; a plain `registry[urn] = handler` collapses them to one (whichever
// async builder wins the Promise.all race), silently dropping the rest.
let addToRegistry = (
  registry: dict<array<registeredHandler>>,
  sourceUrn: string,
  handler: registeredHandler,
) =>
  switch registry->Dict.get(sourceUrn) {
  | Some(handlers) => handlers->Array.push(handler)
  | None => registry->Dict.set(sourceUrn, [handler])
  }

let groupBySource = (
  records: array<PulumiAws.Lambda.CallbackFunction.record>,
): dict<array<PulumiAws.Lambda.CallbackFunction.record>> => {
  let grouped = Dict.make()
  records->Array.forEach(record =>
    switch grouped->Dict.get(record.eventSourceARN) {
    | Some(existing) => existing->Array.push(record)
    | None => grouped->Dict.set(record.eventSourceARN, [record])
    }
  )
  grouped
}

// The exported Lambda handler: group the batch by source ARN and run every
// handler registered for each source (independent storage, so concurrent is
// safe). Each handler carries its own comp so the shared Lambda's log lines
// stay separable per component.
let makeRoutedHandler = (
  ~comp: string,
  registryPromise: promise<dict<array<registeredHandler>>>,
) =>
  async (event: PulumiAws.Lambda.CallbackFunction.event, context: PulumiAws.Lambda.context) => {
    setRequestId(context.awsRequestId)
    let registry = await registryPromise
    let _ =
      await groupBySource(event.records)
      ->Dict.toArray
      ->Array.map(async ((arn, subRecords)) =>
        switch registry->Dict.get(arn)->Option.filter(hs => hs->Array.length > 0) {
        | Some(streamHandlers) =>
          logDebug(
            `found ${streamHandlers->Array.length->Int.toString} handler(s) for ${arn}`,
            {comp: comp},
          )
          let correlationId = extractMetaField(subRecords, "correlationId")
          let causationId = extractMetaField(subRecords, "causationId")
          let timestamp = extractSentTimestamp(subRecords)
          let retryCount = extractRetryCount(subRecords)
          let subEvent: PulumiAws.Lambda.CallbackFunction.event = {records: subRecords}
          let _ =
            await streamHandlers
            ->Array.map(registered =>
              runEffect(
                registered.handler(subEvent, context),
                {
                  correlationId: ?correlationId,
                  causationId: ?causationId,
                  comp: ?registered.comp,
                  plugin: ?registered.plugin,
                  timestamp: ?timestamp,
                  retryCount,
                },
              )
            )
            ->Promise.all
        | None => logWarn("no handler found: " ++ arn, {comp: comp})
        }
      )
      ->Promise.all
    ""
  }
