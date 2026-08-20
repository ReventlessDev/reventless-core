// Typed cold-start core for the ReadModel Lambda entry point.
//
// The "typed core, thin shell" split (docs/plans/done/minimize-lambda-entrypoint-mjs-shell.md):
// ReadModelEntryPoint.mjs keeps only the untyped seams — the dynamic `import()`
// of spec/mappings modules named in HANDLER_CONFIG, the `patchSpecId` /
// `fixMappingsModule` shape fix-ups on those runtime-loaded modules, and the
// ReadModel_Callback.Make functor application consuming them. HANDLER_CONFIG
// parsing, the QueryDb operation assembly (including the id-injection wrap),
// and handler registration live here, fully type-checked; the QueryDb backend
// branch is shared with the StateViewSlice entry point in
// ProjectionEntryPoint_Ops and the routed dispatch boundary lives in
// StreamRoutedEntryPoint_Ops.

type handlerEntry = {
  specModule: string,
  mappingsModule: string,
  queryDbTableName: string,
  sourceUrn: string,
  // Resolved at deploy time and baked into HANDLER_CONFIG
  // (EventCollectorRuntime_Builder_Single) so the shell doesn't re-derive
  // component identity from module paths, and so the string matches the
  // ReScript dispatch boundary's `EventCollector(<Name>)` byte for byte. This
  // Lambda hosts every read model, so the comp is what separates their log
  // lines; the plugin beats the Lambda-name-derived fallback in runEffect.
  comp: option<string>,
  plugin: option<string>,
  pgConnection: option<PgConnection.connectionConfig>,
  stateTopicName: option<string>,
}

// The builder writes `pgConnection` via PgConnection.connectionConfigToJson, so
// the parsed object IS the record shape — cast at the documented JSON contract
// (the AggregateEntryPoint_Ops.asConnectionConfig pattern).
external asPgConnection: JSON.t => PgConnection.connectionConfig = "%identity"

let strOf = (obj: dict<JSON.t>, key: string): option<string> =>
  obj->Dict.get(key)->Option.flatMap(JSON.Decode.string)

let decodeEntry = (json: JSON.t): option<handlerEntry> =>
  json
  ->JSON.Decode.object
  ->Option.map(h => {
    specModule: h->strOf("specModule")->Option.getOr(""),
    mappingsModule: h->strOf("mappingsModule")->Option.getOr(""),
    queryDbTableName: h->strOf("queryDbTableName")->Option.getOr(""),
    sourceUrn: h->strOf("sourceUrn")->Option.getOr(""),
    comp: h->strOf("comp"),
    plugin: h->strOf("plugin"),
    pgConnection: h
    ->Dict.get("pgConnection")
    ->Option.filter(j => j != JSON.Null)
    ->Option.map(asPgConnection),
    stateTopicName: h->strOf("stateTopicName"),
  })

let parseHandlerConfig = (rawJson: string): array<handlerEntry> =>
  rawJson == ""
    ? []
    : rawJson
      ->JSON.parseOrThrow
      ->JSON.Decode.object
      ->Option.flatMap(obj => obj->Dict.get("handlers"))
      ->Option.flatMap(JSON.Decode.array)
      ->Option.getOr([])
      ->Array.filterMap(decodeEntry)

// ── QueryDb operations with id injection ────────────────────────────────────
// Saved read-model states get an `id` key injected (query resolvers and the
// live-update publisher read it off the row). Applied OUTSIDE the live-update
// wrap so the publish sees the id-injected state (id, subId, updatedAt).

let injectId = (id: string, state: JSON.t): JSON.t =>
  switch state {
  | Object(fields) =>
    let injected = fields->Dict.copy
    injected->Dict.set("id", JSON.String(id))
    JSON.Object(injected)
  | other => other
  }

let withInjectedId = (
  base: ReventlessCore.QueryDb_Adapter.operations,
): ReventlessCore.QueryDb_Adapter.operations => {
  ...base,
  save: (id, state, saveMode, ttl) => base.save(id, injectId(id, state), saveMode, ttl),
  saveBatch: items =>
    base.saveBatch(items->Array.map(((id, state, ttl)) => (id, injectId(id, state), ttl))),
}

type specInfo = {
  config: option<ProjectionEntryPoint_Ops.specConfig>,
  subIdConfig: option<Reventless.ReadModel.subIdConfig<JSON.t>>,
  // Read off the runtime-loaded spec module; `None` on a module that predates it.
  stateSchema: option<S.t<unknown>>,
}

let buildOperations = (
  entry: handlerEntry,
  spec: specInfo,
): ReventlessCore.QueryDb_Adapter.operations =>
  ProjectionEntryPoint_Ops.makeQueryDbOps(
    ~queryDbTableName=entry.queryDbTableName,
    ~pgConnection=entry.pgConnection,
    ~stateTopicName=entry.stateTopicName,
    ~indexes=ProjectionEntryPoint_Ops.indexesOf(spec.config),
    ~subIdField=ProjectionEntryPoint_Ops.subIdFieldOf(spec.subIdConfig),
  )
  ->ProjectionEntryPoint_Ops.withUnionMemberTypes(~stateSchema=spec.stateSchema)
  ->withInjectedId

let makeRegisteredHandler = (
  entry: handlerEntry,
  handleJsonEvents: ReventlessCore.EventCollector.jsonEventsHandler,
): StreamRoutedEntryPoint_Ops.registeredHandler => {
  handler: StreamRoutedEntryPoint_Ops.toStreamHandler(handleJsonEvents),
  comp: ?entry.comp,
  plugin: ?entry.plugin,
}
