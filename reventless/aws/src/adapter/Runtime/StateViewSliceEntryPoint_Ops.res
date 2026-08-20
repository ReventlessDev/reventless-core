// Typed cold-start core for the StateViewSlice Lambda entry point.
//
// The "typed core, thin shell" split (docs/plans/done/minimize-lambda-entrypoint-mjs-shell.md):
// StateViewSliceEntryPoint.mjs keeps only the inherently-untyped seam — the
// dynamic `import()` of spec/projection modules named in HANDLER_CONFIG and the
// reads of their exports. HANDLER_CONFIG parsing (including the compact-v2
// expansion), the QueryDb operation assembly, and the whole projection stream
// pipeline (envelope decode → sury event parse → project → handleAction) live
// here, fully type-checked; the QueryDb backend branch is shared with the
// ReadModel entry point in ProjectionEntryPoint_Ops and the routed dispatch
// boundary lives in StreamRoutedEntryPoint_Ops.

type handlerEntry = {
  specModule: string,
  projectionModule: string,
  queryDbTableName: string,
  sourceUrn: string,
  // B3.3: per-slice AppSync Events channel root (list field name). Present only
  // for subscription-enabled (Stream) Postgres view slices.
  stateTopicName: option<string>,
  pgConnection: option<PgConnection.connectionConfig>,
}

// The builder writes `pgConnection` via PgConnection.connectionConfigToJson, so
// the parsed object IS the record shape — cast at the documented JSON contract
// (the AggregateEntryPoint_Ops.asConnectionConfig pattern).
external asPgConnection: JSON.t => PgConnection.connectionConfig = "%identity"

let strOf = (obj: dict<JSON.t>, key: string): option<string> =>
  obj->Dict.get(key)->Option.flatMap(JSON.Decode.string)

let pgConnectionOf = (obj: dict<JSON.t>): option<PgConnection.connectionConfig> =>
  obj
  ->Dict.get("pgConnection")
  ->Option.filter(j => j != JSON.Null)
  ->Option.map(asPgConnection)

// HANDLER_CONFIG is emitted compact (StateViewSliceRuntime_Builder_Single) to
// stay under AWS Lambda's 4KB env-var limit: a shared module-path `base`, a
// shared `sourceUrn`, and a shared `pgConnection` are hoisted out (all of a
// plugin's slices follow the platform backend toggle), and per-handler keys are
// shortened to s/p/q/u/t. Expand back to the full handlerEntry shape. Legacy
// full-key entries pass through with their own per-entry fields.
let parseHandlerConfig = (rawJson: string): array<handlerEntry> =>
  rawJson == ""
    ? []
    : {
        let obj =
          rawJson
          ->JSON.parseOrThrow
          ->JSON.Decode.object
          ->Option.getOr(Dict.make())
        let base = obj->strOf("base")->Option.getOr("")
        let sharedUrn = obj->strOf("sourceUrn")->Option.getOr("")
        let sharedPgConnection = obj->pgConnectionOf
        obj
        ->Dict.get("handlers")
        ->Option.flatMap(JSON.Decode.array)
        ->Option.getOr([])
        ->Array.filterMap(item =>
          item
          ->JSON.Decode.object
          ->Option.map(h =>
            switch h->strOf("specModule") {
            | Some(specModule) => {
                specModule,
                projectionModule: h->strOf("projectionModule")->Option.getOr(""),
                queryDbTableName: h->strOf("queryDbTableName")->Option.getOr(""),
                sourceUrn: h->strOf("sourceUrn")->Option.getOr(""),
                stateTopicName: h->strOf("stateTopicName"),
                pgConnection: h->pgConnectionOf,
              }
            | None => {
                specModule: base ++ h->strOf("s")->Option.getOr(""),
                projectionModule: base ++ h->strOf("p")->Option.getOr(""),
                queryDbTableName: h->strOf("q")->Option.getOr(""),
                sourceUrn: h->strOf("u")->Option.getOr(sharedUrn),
                stateTopicName: h->strOf("t"),
                pgConnection: sharedPgConnection,
              }
            }
          )
        )
      }

// ── Projection stream pipeline ──────────────────────────────────────────────

// Events arrive as `{id, meta, recordedAt, event}` envelopes
// (Util_DynamoDbStream_Runtime.buildJsonEvent' / PgChangeFeedRelay). Surface
// `meta` + `recordedAt` to the projection as the `consumed` envelope;
// `recordedAt` defaults to "" if a producer omitted it. `meta` is already
// schema-shaped JSON written by the producer — cast at the documented contract
// (absent maps to undefined, exactly what the former JS passed through).
external asMeta: option<JSON.t> => Reventless.Message.meta = "%identity"

type envelope<'event> = {
  event: JSON.t,
  meta: Reventless.Message.meta,
  recordedAt: string,
}

let decodeEnvelope = (json: JSON.t): envelope<'event> => {
  let fields = json->JSON.Decode.object
  {
    event: switch fields->Option.flatMap(f => f->Dict.get("event")) {
    | Some(JSON.Null) | None => json
    | Some(event) => event
    },
    meta: fields->Option.flatMap(f => f->Dict.get("meta"))->asMeta,
    recordedAt: fields
    ->Option.flatMap(f => f->Dict.get("recordedAt"))
    ->Option.flatMap(JSON.Decode.string)
    ->Option.getOr(""),
  }
}

let exnMessage = StreamRoutedEntryPoint_Ops.exnMessage

// The typed core of buildJsonEventsHandler: decode each envelope, parse the
// event against the slice's consumed-event schema, project, and run every
// resulting action against the view table. A decode failure logs and yields no
// actions (the batch continues — at-least-once delivery would otherwise wedge
// the whole source on one malformed record).
let makeJsonEventsHandler = (
  ~sliceName: string,
  ~eventSchema: S.t<'event>,
  ~project: Reventless.StateViewSlice.consumed<'event> => array<
    Reventless.Projection.action<string, JSON.t>,
  >,
  ~queryDbOps: ReventlessCore.QueryDb_Adapter.operations,
  ~subIdConfig: option<Reventless.ReadModel.subIdConfig<JSON.t>>,
): ReventlessCore.EventCollector.jsonEventsHandler =>
  stream =>
    stream
    ->Stream.mapEffect(json =>
      Effect.sync(() =>
        try {
          let {event, meta, recordedAt} = decodeEnvelope(json)
          project({event: event->Reventless.Util_Sury.fromJson(eventSchema), meta, recordedAt})
        } catch {
        | exn =>
          StreamRoutedEntryPoint_Ops.logError(
            "failed to decode event",
            {comp: "StateViewSliceRuntime", detail: exnMessage(exn)},
          )
          []
        }
      )
    )
    ->Stream.flatMap(actions => Stream.fromIterable(actions))
    ->Stream.runForEach(action =>
      // Thread the slice's `subIdConfig` (generated from `@subId`) so
      // sub-id-dependent actions like `UpdateMultiState` can resolve the sort
      // key. Dropping it here made every such action hit the
      // `MissingSubIdConfig` guard and silently write nothing, while the
      // test-harness callback path (which threads it) stayed green. `None` for
      // slices without an `@subId` is correct — those never emit sub-id
      // actions. `~comp` is the slice's spec name — attribution for
      // Projection.handleAction's debug-lazy action log.
      Effect.promise(() =>
        ReventlessCore.Projection.handleAction(~comp=sliceName, action, queryDbOps, subIdConfig)
      )->Effect.map(_ => ())
    )

// ── Handler assembly (called by the shell per HANDLER_CONFIG entry) ─────────
// `sliceModules` types the shell's reads off the two dynamically imported
// modules: the spec module exports `name` / `consumedEventSchema` / `config` /
// `subIdConfig`; the `project` function lives in the sibling projection module
// (`<Name>_Projection.res`).

type sliceModules<'event> = {
  name: string,
  consumedEventSchema: S.t<'event>,
  project: Reventless.StateViewSlice.consumed<'event> => array<
    Reventless.Projection.action<string, JSON.t>,
  >,
  config: option<ProjectionEntryPoint_Ops.specConfig>,
  subIdConfig: option<Reventless.ReadModel.subIdConfig<JSON.t>>,
  // Same union stamp the read-model path needs; a slice's state can hold one too.
  stateSchema: option<S.t<unknown>>,
}

let makeRegisteredHandler = (
  entry: handlerEntry,
  modules: sliceModules<'event>,
): StreamRoutedEntryPoint_Ops.registeredHandler => {
  let queryDbOps = ProjectionEntryPoint_Ops.makeQueryDbOps(
    ~queryDbTableName=entry.queryDbTableName,
    ~pgConnection=entry.pgConnection,
    ~stateTopicName=entry.stateTopicName,
    ~indexes=ProjectionEntryPoint_Ops.indexesOf(modules.config),
    ~subIdField=ProjectionEntryPoint_Ops.subIdFieldOf(modules.subIdConfig),
  )->ProjectionEntryPoint_Ops.withUnionMemberTypes(~stateSchema=modules.stateSchema)
  {
    handler: StreamRoutedEntryPoint_Ops.toStreamHandler(
      makeJsonEventsHandler(
        ~sliceName=modules.name,
        ~eventSchema=modules.consumedEventSchema,
        ~project=modules.project,
        ~queryDbOps,
        ~subIdConfig=modules.subIdConfig,
      ),
    ),
    // Matches the `StateViewSlice(<name>)` shape the rest of the framework
    // logs under.
    comp: `StateViewSlice(${modules.name})`,
  }
}
