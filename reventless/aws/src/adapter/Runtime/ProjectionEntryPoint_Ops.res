// Typed cold-start core shared by the two projection Lambda entry points
// (ReadModelEntryPoint.mjs, StateViewSliceEntryPoint.mjs).
//
// The "typed core, thin shell" split (docs/plans/minimize-lambda-entrypoint-mjs-shell.md):
// both shells route DynamoDB-stream / SQS-feed records to per-source-URN handler
// lists and build the QueryDb operation set (DynamoDB or Postgres, live-update
// wrapped) for each projection. That shared machinery lives here, fully
// type-checked; the shells keep only the dynamic `import()` of spec/mappings
// modules named in HANDLER_CONFIG and the functor applications consuming them.
//
// NOT folded into QueryDbEntryPoint_Ops: that module is also imported by
// DcbCommandTopicEntryPoint.mjs, and the Postgres branch here would drag
// `pg`/PgRuntime (and the stream-channel modules) into the DCB command
// Lambda's cold-start graph.
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

@val @scope("process") external processEnv: dict<string> = "env"

let exnMessage = (exn: exn): string =>
  exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown error")

// ── Runtime-loaded spec-module reads (typed at the seam) ────────────────────
// The shells read `config` / `subIdConfig` off dynamically imported spec
// modules; these are the shapes those reads are typed against. `indexes` is
// optional so a module whose `config` lacks the field degrades to `[]` exactly
// as the former JS `(config && config.indexes) || []` did.

type specConfig = {indexes?: array<Reventless.ReadModel.indexConfig>}

let indexesOf = (config: option<specConfig>): array<Reventless.ReadModel.indexConfig> =>
  config->Option.flatMap(c => c.indexes)->Option.getOr([])

let subIdFieldOf = (
  subIdConfig: option<Reventless.ReadModel.subIdConfig<JSON.t>>,
): option<string> => subIdConfig->Option.map(c => c.subIdField)

// ── QueryDb operations (DynamoDB / Postgres backend branch) ─────────────────
// `pgConnection`, when present, selects the Postgres QueryDb runtime for the
// projection's view table (`queryDbTableName` is then the spec name, the shared
// `qdb_<name>` discriminator). Absent → the DynamoDB operation set.
//
// On a subscription-enabled (Stream) Postgres projection, every save/delete
// also publishes a live-update descriptor (no DynamoDB stream exists).
// `stateTopicName` (present only for stream projections) + APPSYNC_ENDPOINT
// gate it; absent → withLiveUpdates returns the ops unchanged.

type liveConfig = {
  endpoint?: string,
  region?: string,
  topicName?: string,
  subIdField?: string,
}

@module("./StateTopicPublish.mjs")
external withLiveUpdates: (
  ReventlessCore.QueryDb_Adapter.operations,
  liveConfig,
) => ReventlessCore.QueryDb_Adapter.operations = "withLiveUpdates"

let makeQueryDbOps = (
  ~queryDbTableName: string,
  ~pgConnection: option<PgConnection.connectionConfig>,
  ~stateTopicName: option<string>,
  ~indexes: array<Reventless.ReadModel.indexConfig>,
  ~subIdField: option<string>,
): ReventlessCore.QueryDb_Adapter.operations =>
  switch pgConnection {
  | Some(connection) =>
    QueryDbStorage_Postgres_Runtime.opsFor(
      connection,
      ~name=queryDbTableName,
      ~indexes,
      ~subIdField?,
    )->withLiveUpdates({
      endpoint: ?(processEnv->Dict.get("APPSYNC_ENDPOINT")),
      region: ?(processEnv->Dict.get("AWS_REGION")),
      topicName: ?stateTopicName,
      subIdField: ?subIdField,
    })
  | None => QueryDbEntryPoint_Ops.makeDynamoQueryDbOps(~tableName=queryDbTableName)
  }

// ── Handler registry + routed dispatch boundary ─────────────────────────────

type streamHandler = (
  PulumiAws.Lambda.CallbackFunction.event,
  PulumiAws.Lambda.context,
) => Effect.t<unit, string, unit>

// One Lambda hosts every projection of its kind, so each handler carries the
// comp of the projection it runs (and, for read models, the owning plugin —
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

// Multiple projections can share one source stream — e.g. every admin read
// model (Plugins, PluginHistory, PlatformEventGraph, UIFragmentRegistry)
// projects the Plugin aggregate's EventLog stream. Accumulate ALL handlers per
// source URN; a plain `registry[urn] = handler` collapses them to one
// (whichever async builder wins the Promise.all race), silently dropping the
// rest — which leaves their QueryDbs empty.
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
// projection registered for each source (independent QueryDbs, so concurrent
// is safe). Each handler carries its own comp so the shared Lambda's log lines
// stay separable per projection.
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
