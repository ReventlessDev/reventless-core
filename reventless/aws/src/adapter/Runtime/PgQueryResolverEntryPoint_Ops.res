// Typed cold-start core for the shared PgQueryResolver Lambda entry point
// (B3.2b).
//
// The "typed core, thin shell" split (docs/plans/minimize-lambda-entrypoint-mjs-shell.md):
// PgQueryResolverEntryPoint.mjs keeps only the untyped seam — the dynamic
// `import()` of each spec package named in QUERY_RESOLVER_CONFIG, the
// `patchSpecId` fix-up, and the reads of the runtime-loaded module's exports
// (config / subIdConfig / stateSchema / authorization), handed back here as a
// typed `specInfo`. QUERY_RESOLVER_CONFIG parsing, the pool/engine
// construction (QueryEnginePostgres.Make over an inline module capturing the
// container-lifetime pool), the push-down record, and the per-read-model
// binding registration live here, fully type-checked.

@module("./HandlerFactoryHelpers.mjs") @scope("log")
external logDebug: (string, StreamRoutedEntryPoint_Ops.dispatchOpts) => unit = "debug"

// ── QUERY_RESOLVER_CONFIG ───────────────────────────────────────────────────
// Written by PgQueryResolver_Builder: one shared pgConnection + one handler
// per read model + the Relay node type → read-model map (B3.2c).

type handlerEntry = {
  readModelName: string,
  specModule: string,
  labelField: string,
  includeIdParam: bool,
}

type resolverConfig = {
  pgConnection: option<PgConnection.connectionConfig>,
  handlers: array<handlerEntry>,
  nodeTypes: dict<string>,
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
    readModelName: h->strOf("readModelName")->Option.getOr(""),
    specModule: h->strOf("specModule")->Option.getOr(""),
    labelField: h->strOf("labelField")->Option.getOr(""),
    includeIdParam: h
    ->Dict.get("includeIdParam")
    ->Option.flatMap(JSON.Decode.bool)
    ->Option.getOr(false),
  })

let parseResolverConfig = (rawJson: string): resolverConfig => {
  let obj =
    (rawJson == "" ? `{"handlers":[]}` : rawJson)
    ->JSON.parseOrThrow
    ->JSON.Decode.object
    ->Option.getOr(Dict.make())
  {
    pgConnection: obj
    ->Dict.get("pgConnection")
    ->Option.filter(j => j != JSON.Null)
    ->Option.map(asPgConnection),
    handlers: obj
    ->Dict.get("handlers")
    ->Option.flatMap(JSON.Decode.array)
    ->Option.getOr([])
    ->Array.filterMap(decodeEntry),
    nodeTypes: obj
    ->Dict.get("nodeTypes")
    ->Option.flatMap(JSON.Decode.object)
    ->Option.getOr(Dict.make())
    ->Dict.toArray
    ->Array.filterMap(((k, v)) => v->JSON.Decode.string->Option.map(s => (k, s)))
    ->Dict.fromArray,
  }
}

let registerNodeTypes = (config: resolverConfig): unit =>
  config.nodeTypes
  ->Dict.toArray
  ->Array.forEach(((typeName, readModelName)) =>
    PgQueryResolver_Lambda.registerNodeType(~typeName, ~readModelName)
  )

// ── Push-downs ──────────────────────────────────────────────────────────────

// A bounded full-materialisation for the list fallback (shapes listPage
// declines). Kept high; the fallback is only hit for search/searchPrefix/ids/
// backward pagination, which the AutoUI does not issue for large models.
let scanAllLimit = 100000

// Container-lifetime pool (memoised by poolFor); the engine and each binding's
// ops set share it, so the Lambda holds one pool regardless of read model
// count.
let makePushdowns = (
  pgConnection: PgConnection.connectionConfig,
): PgQueryResolver_Lambda.pushdowns => {
  module Engine = ReventlessPostgres.QueryEnginePostgres.Make({
    let pool = PgRuntime.poolFor(pgConnection)
  })
  {
    indexLookup: Engine.indexLookup,
    byIds: Engine.byIds,
    listPage: Engine.listPage,
    itemsPage: Engine.itemsPage,
    scanAll: (~readModelName) => Engine.scan(~readModelName, ~filterConfigs=[], ~limit=scanAllLimit),
  }
}

// ── Binding registration ────────────────────────────────────────────────────
// The runtime-loaded spec module's exports, read by the shell and passed as a
// typed record; `authorization` is the compiled string variant (e.g.
// "AllowAuthenticated") injected on the spec by @@reventless.spec — the shape
// Reventless.Authorization.isAllowed matches on.

type specInfo = {
  config: option<ProjectionEntryPoint_Ops.specConfig>,
  subIdConfig: option<Reventless.ReadModel.subIdConfig<JSON.t>>,
  stateSchema: S.t<unknown>,
  authorization: Reventless.Authorization.permission,
}

let registerBinding = (
  pushdowns: PgQueryResolver_Lambda.pushdowns,
  pgConnection: PgConnection.connectionConfig,
  entry: handlerEntry,
  spec: specInfo,
): unit => {
  let indexes = ProjectionEntryPoint_Ops.indexesOf(spec.config)
  let subIdField = ProjectionEntryPoint_Ops.subIdFieldOf(spec.subIdConfig)
  PgQueryResolver_Lambda.register(
    ~readModelName=entry.readModelName,
    {
      ops: QueryDbStorage_Postgres_Runtime.opsFor(
        pgConnection,
        ~name=entry.readModelName,
        ~indexes,
        ~subIdField=?subIdField,
      ),
      pushdowns,
      indexes,
      subIdField,
      capability: ReventlessCore.GraphQL_FragmentGenerator.deriveServerCapability(
        ~entityName=entry.readModelName,
        spec.stateSchema,
      ),
      labelField: entry.labelField,
      includeIdParam: entry.includeIdParam,
      authorization: spec.authorization,
      // From the same schema `capability` is derived from, one line above, so the
      // two cannot end up disagreeing about this read model's fields.
      ownerField: Reventless.Owner.fieldNames(spec.stateSchema)->Array.get(0),
      retiredField: spec.stateSchema
      ->Reventless.StateAnnotations.getSpec
      ->Option.flatMap(a => a.retired)
      ->Option.map(r => r.field),
    },
  )
  logDebug("registered resolver binding for " ++ entry.readModelName, {comp: "PgQueryResolver"})
}
