// Runtime handler for the shared Postgres GraphQL-read Lambda (B3.2).
//
// Postgres-backed read models have no per-table AppSync data source, so their
// GraphQL Query fields route through one in-VPC "PgQueryResolver" Lambda
// registered as an AppSync Lambda data source (B3.2b). Each resolver field's
// APPSYNC_JS template invokes this Lambda with
//   { readModelName, kind, index?, arguments, identity }
// and this handler dispatches to the Postgres query push-downs
// (QueryEnginePostgres) + the shared connection spec (QueryDbListQuery).
//
// This module is the provider-agnostic *dispatch* — the headless twin of
// reventless-local's `QueryDbResolvers_GraphQL` (which registers graphql-yoga
// resolvers). It returns JSON straight to AppSync instead. The per-read-model
// context (ops set, push-downs, indexes, capability, …) is bound at Lambda init
// by the entry point (PgQueryResolverEntryPoint.mjs, B3.2b) and registered here;
// `dispatch` itself is pure over a `binding`, so it is unit-tested with an
// in-memory mock (no Postgres) — the SQL correctness lives in
// QueryEnginePostgres and is covered by its PG_URL-gated parity test.

let log = ReventlessCore.Logger.fromEnv()

// Wire payload from the resolver template. `arguments` mirrors the field name the
// other Invoke templates use (QueryInterceptor_Lambda, invokeCommandGenerator).
type payload = {
  readModelName: string,
  kind: string,
  index?: string,
  arguments: JSON.t,
  identity: Reventless.Identity.t,
}

// The Postgres query push-downs a binding needs (QueryEnginePostgres.Make
// provides these; the mock in tests provides in-memory equivalents).
type pushdowns = {
  indexLookup: (~readModelName: string, string, string) => promise<array<JSON.t>>,
  byIds: (~readModelName: string, array<string>) => promise<array<JSON.t>>,
  listPage: (
    ~readModelName: string,
    ~argsDict: dict<JSON.t>,
    ~capability: ReventlessCore.GraphQL_FragmentGenerator.serverCapability,
    ~labelField: string,
  ) => promise<option<JSON.t>>,
  // Sub-id connection ({single}Items) — keyset over sub_key within a partition.
  itemsPage: (
    ~readModelName: string,
    ~subIdField: string,
    ~id: string,
    ~argsDict: dict<JSON.t>,
  ) => promise<JSON.t>,
  // Full materialisation for the list fallback (shapes listPage declines).
  scanAll: (~readModelName: string) => promise<array<JSON.t>>,
}

// Per-read-model dispatch context, bound once at Lambda init.
type binding = {
  ops: ReventlessCore.QueryDb_Adapter.operations,
  pushdowns: pushdowns,
  indexes: array<Reventless.ReadModel.indexConfig>,
  subIdField: option<string>,
  capability: ReventlessCore.GraphQL_FragmentGenerator.serverCapability,
  labelField: string,
  includeIdParam: bool,
  authorization: Reventless.Authorization.permission,
}

// -- arg helpers -------------------------------------------------------------
let argObj = (args: JSON.t): dict<JSON.t> =>
  args->JSON.Decode.object->Option.getOr(Dict.make())
let argStr = (args: JSON.t, key: string): option<string> =>
  args->argObj->Dict.get(key)->Option.flatMap(JSON.Decode.string)
let argStrs = (args: JSON.t, key: string): array<string> =>
  args
  ->argObj
  ->Dict.get(key)
  ->Option.flatMap(JSON.Decode.array)
  ->Option.getOr([])
  ->Array.filterMap(JSON.Decode.string)

// Add `id` (= partition key) to an item when absent — matches the shape the
// DynamoDB resolvers and the shared spec return.
let withId = (item: JSON.t, id: string): JSON.t =>
  switch item->JSON.Decode.object {
  | Some(obj) if obj->Dict.get("id")->Option.isNone =>
    let copy = Dict.copy(obj)
    copy->Dict.set("id", JSON.Encode.string(id))
    JSON.Encode.object(copy)
  | _ => item
  }

let emptyConnection = (): JSON.t =>
  ReventlessCore.QueryDbListQuery.buildConnection(
    ~pageItems=[],
    ~hasNextPage=false,
    ~hasPreviousPage=false,
    ~cursorValueOf=_ => "",
  )

// Spec-level authorization then the (optional) user interceptor — mirrors
// QueryDbResolvers_GraphQL.runInterceptor. Denials return the kind's empty shape
// (the provider-agnostic resolver behaviour), not an error.
let runInterceptor = async (~binding, ~payload): ReventlessCore.QueryDb_Callback.interceptResult => {
  if !Reventless.Authorization.isAllowed(binding.authorization, payload.identity) {
    Deny("Forbidden")
  } else {
    switch ReventlessCore.QueryDb_Callback.queryInterceptorHook.contents {
    | None => Allow
    | Some(interceptor) =>
      await interceptor(
        ~identity=payload.identity,
        ~readModelName=payload.readModelName,
        ~args=payload.arguments,
      )
    }
  }
}

let dispatch = async (~binding: binding, ~payload: payload): JSON.t => {
  let rm = payload.readModelName
  switch await runInterceptor(~binding, ~payload) {
  | Deny(_) =>
    // Empty shape per kind (null for single, connection for list/items, [] else).
    switch payload.kind {
    | "getById" => JSON.Encode.null
    | "list" | "items" => emptyConnection()
    | _ => JSON.Encode.array([])
    }
  | Allow =>
    switch payload.kind {
    | "getById" =>
      let id = payload.arguments->argStr("id")->Option.getOr("")
      switch await binding.ops.load(id) {
      | Ok(items) =>
        switch items->Array.get(0) {
        | Some(item) => binding.includeIdParam ? withId(item, id) : item
        | None => JSON.Encode.null
        }
      | Error(_) => JSON.Encode.null
      }

    | "byIds" =>
      let ids = payload.arguments->argStrs("ids")
      JSON.Encode.array(await binding.pushdowns.byIds(~readModelName=rm, ids))

    | "items" =>
      // Sub-id connection: {single}Items(id, filter, first/after/last/before).
      // Requires a subIdField; without one it's an empty connection.
      switch binding.subIdField {
      | Some(subIdField) =>
        let id = payload.arguments->argStr("id")->Option.getOr("")
        await binding.pushdowns.itemsPage(
          ~readModelName=rm,
          ~subIdField,
          ~id,
          ~argsDict=payload.arguments->argObj,
        )
      | None => emptyConnection()
      }

    | "index" =>
      // The index arg name is the index; its stored field is idField ?? index.
      let indexName = payload.index->Option.getOr("")
      let field =
        binding.indexes
        ->Array.find(ic => ic.index === indexName)
        ->Option.flatMap(ic => ic.idField)
        ->Option.getOr(indexName)
      let value = payload.arguments->argStr(indexName)->Option.getOr("")
      JSON.Encode.array(await binding.pushdowns.indexLookup(~readModelName=rm, field, value))

    | "list" =>
      let argsDict = payload.arguments->argObj
      switch await binding.pushdowns.listPage(
        ~readModelName=rm,
        ~argsDict,
        ~capability=binding.capability,
        ~labelField=binding.labelField,
      ) {
      | Some(conn) => conn
      | None =>
        // Shapes listPage declines (search/searchPrefix/ids/backward) → run the
        // shared spec over the materialised model. No Relay global-id decoding
        // in the Lambda, so `decodeLocalId` is a no-op (the `ids` filter still
        // matches raw item ids).
        let items = await binding.pushdowns.scanAll(~readModelName=rm)
        ReventlessCore.QueryDbListQuery.run(
          ~items,
          ~argsDict,
          ~capability=binding.capability,
          ~labelField=binding.labelField,
          ~decodeLocalId=_ => None,
        )
      }

    | other =>
      // Fail loudly on unmapped kinds (feature-parity guard, per the B3.2 plan).
      log.error(~comp="PgQueryResolver_Lambda", `unmapped resolver kind '${other}' for ${rm}`)
      JsError.throwWithMessage(`PgQueryResolver: unmapped resolver kind '${other}' for ${rm}`)
    }
  }
}

// Per-read-model binding registry, populated by the entry point at Lambda init.
let bindings: dict<binding> = Dict.make()
let register = (~readModelName: string, binding: binding): unit =>
  bindings->Dict.set(readModelName, binding)

let handler = async (payload: payload, _context) =>
  switch bindings->Dict.get(payload.readModelName) {
  | Some(binding) => await dispatch(~binding, ~payload)
  | None =>
    JsError.throwWithMessage(
      "PgQueryResolver: no binding registered for read model " ++ payload.readModelName,
    )
  }
