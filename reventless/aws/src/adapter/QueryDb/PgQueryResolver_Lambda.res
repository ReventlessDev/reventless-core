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

@val external atob: string => string = "atob"

// Where a cross-table resolver reads the target's sort-key value from.
// `kind`: "field" (the parent object) | "arg" (the GraphQL arguments).
type subIdSource = {kind: string, name: string}

// Wire payload from the resolver template. `arguments` mirrors the field name the
// other Invoke templates use (QueryInterceptor_Lambda, invokeCommandGenerator).
// The cross-table fields (B3.2c) are present only for resolveOne/resolveMany:
type payload = {
  readModelName: string,
  kind: string,
  index?: string,
  // Cross-table (@resolves/@resolvesMany) — see B3.2c dispatch below.
  target?: string,
  source?: JSON.t,
  sourceIdField?: string,
  sourceIdsField?: string,
  sourceSubId?: subIdSource,
  targetIndex?: string,
  targetIndexIdField?: string,
  multi?: bool,
  // Auth-table pipeline (B3.2c): a group-restricted index. Group members must
  // own the resource (the auth table maps index value → {<group>Id: username});
  // non-members pass through (mirrors the DynamoDB pipeline's earlyReturn).
  authTable?: string,
  authGroup?: string,
  arguments: JSON.t,
  identity: Reventless.Identity.t,
}

// "Owner" → "ownerId" (auth-table owner field name, matching authorizeIndexedAccess).
let authIdField = (group: string): string =>
  switch group->String.get(0) {
  | Some(c) => c->String.toLowerCase ++ group->String.slice(~start=1, ~end=group->String.length) ++ "Id"
  | None => "Id"
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
    ~ownerScope: (string, string)=?,
    ~retiredScope: string=?,
  ) => promise<option<JSON.t>>,
  // Sub-id connection ({single}Items) — keyset over sub_key within a partition.
  itemsPage: (
    ~readModelName: string,
    ~subIdField: string,
    ~id: string,
    ~argsDict: dict<JSON.t>,
    ~ownerScope: (string, string)=?,
    ~retiredScope: string=?,
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
  /** The state's `@owner` field, when it declares one. Derived at Lambda init
      from the same schema `capability` comes from, so the two cannot disagree
      about which fields this read model has. */
  ownerField: option<string>,
  retiredField: option<string>,
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

// `lookupBinding` resolves another read model's binding by key — needed only for
// the auth-table pipeline (the auth table is another read model, loaded by the
// index value). The handler passes the module-level registry; tests pass a mock.
let dispatch = async (
  ~binding: binding,
  ~lookupBinding: string => option<binding>=_ => None,
  ~payload: payload,
): JSON.t => {
  let rm = payload.readModelName
  switch await runInterceptor(~binding, ~payload) {
  | Deny(_) =>
    // Empty shape per kind (null for single, connection for list/items, [] else).
    let isMulti = payload.multi->Option.getOr(false)
    switch payload.kind {
    | "getById" => JSON.Encode.null
    | "resolveOne" if !isMulti => JSON.Encode.null
    | "list" | "items" => emptyConnection()
    | _ => JSON.Encode.array([])
    }
  | Allow =>
    // Post-read narrowing for the doors that hand back rows rather than a page.
    // Same decision as the list door takes; applied per row because there is no
    // query to push it into.
    let ownerAllows = (item: JSON.t) =>
      switch payload.identity->Reventless.OwnerScope.decide(~ownerField=binding.ownerField) {
      | Unscoped => true
      | RefuseOwned => false
      | ScopeTo(field, required) =>
        item->argStr(field)->Option.mapOr(false, v => v == required)
      }
    // The caller's request to see the archive, honoured only where the
    // classification says it counts.
    let askedForRetired =
      payload.arguments
      ->argObj
      ->Dict.get("includeRetired")
      ->Option.flatMap(JSON.Decode.bool)
      ->Option.getOr(false)
    let retiredScope =
      payload.identity
      ->Reventless.OwnerScope.decideRetired(
        ~retiredField=binding.retiredField,
        ~asked=askedForRetired,
      )
      ->Reventless.OwnerScope.retiredScopeOf
    // Absent or non-boolean keeps the row, as in `QueryDbListQuery`.
    let retiredAllows = (item: JSON.t) =>
      switch retiredScope {
      | None => true
      | Some(field) =>
        item
        ->JSON.Decode.object
        ->Option.flatMap(d => d->Dict.get(field))
        ->Option.flatMap(JSON.Decode.bool)
        ->Option.getOr(false) == false
      }
    switch payload.kind {
    | "getById" =>
      let id = payload.arguments->argStr("id")->Option.getOr("")
      let loadKey = async key =>
        switch await binding.ops.load(key) {
        | Ok(items) => items->Array.get(0)
        | Error(_) => None
        }
      // A caller holding a row's Relay global id must reach the row through this
      // door too. Raw key first — it is what this door has always taken, and a
      // key that merely looks like base64 must keep resolving to its own row.
      let (resolvedKey, found) = switch (
        await loadKey(id),
        ReventlessCore.Api_Ids.alternateKey(id),
      ) {
      | (None, Some(localId)) => (localId, await loadKey(localId))
      | (found, _) => (id, found)
      }
      switch found {
      // A row the caller does not own answers as "not found". Saying "not yours"
      // instead would make this door an oracle for which ids exist.
      | Some(item) if !ownerAllows(item) || !retiredAllows(item) => JSON.Encode.null
      | Some(item) => binding.includeIdParam ? withId(item, resolvedKey) : item
      | None => JSON.Encode.null
      }

    | "byIds" =>
      let ids = payload.arguments->argStrs("ids")
      let found = await binding.pushdowns.byIds(~readModelName=rm, ids)
      // Only pay for the second lookup when the first came up short, and only for
      // the ids that are global ones.
      let missing =
        found->Array.length < ids->Array.length
          ? ids->Array.filterMap(ReventlessCore.Api_Ids.alternateKey)
          : []
      let extra = missing->Array.length > 0
        ? await binding.pushdowns.byIds(~readModelName=rm, missing)
        : []
      JSON.Encode.array(
        Array.concat(found, extra)->Array.filter(item => ownerAllows(item) && retiredAllows(item)),
      )

    | "items" =>
      // Sub-id connection: {single}Items(id, filter, first/after/last/before).
      // Requires a subIdField; without one it's an empty connection.
      switch binding.subIdField {
      | Some(subIdField) =>
        let id = payload.arguments->argStr("id")->Option.getOr("")
        switch payload.identity->Reventless.OwnerScope.decide(~ownerField=binding.ownerField) {
        | RefuseOwned => emptyConnection()
        | decision =>
          await binding.pushdowns.itemsPage(
            ~readModelName=rm,
            ~subIdField,
            ~id,
            ~argsDict=payload.arguments->argObj,
            ~ownerScope=?Reventless.OwnerScope.scopeOf(decision),
            ~retiredScope?,
          )
        }
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
      // Auth-table pipeline: a group-restricted index. Non-members pass through;
      // members must own the resource (auth table maps index value →
      // {<group>Id: username}). Auth table is another read model, loaded via the
      // registry (unsupported → deny if it isn't Postgres-registered).
      let authorized = switch (payload.authGroup, payload.authTable) {
      | (Some(group), Some(authTable)) =>
        if !Reventless.Identity.hasGroup(payload.identity, group) {
          true
        } else {
          switch lookupBinding(authTable) {
          | Some(authBinding) =>
            switch await authBinding.ops.load(value) {
            | Ok(items) =>
              items
              ->Array.get(0)
              ->Option.flatMap(row => row->argStr(authIdField(group)))
              ->Option.mapOr(false, owner => owner == payload.identity.username)
            | Error(_) => false
            }
          | None => false
          }
        }
      | _ => true
      }
      if authorized {
        JSON.Encode.array(
          (await binding.pushdowns.indexLookup(~readModelName=rm, field, value))->Array.filter(
            item => ownerAllows(item) && retiredAllows(item),
          ),
        )
      } else {
        JSON.Encode.array([])
      }

    | "list" =>
      let argsDict = payload.arguments->argObj
      switch payload.identity->Reventless.OwnerScope.decide(~ownerField=binding.ownerField) {
      | RefuseOwned => emptyConnection()
      | decision =>
        let ownerScope = Reventless.OwnerScope.scopeOf(decision)
        switch await binding.pushdowns.listPage(
          ~readModelName=rm,
          ~argsDict,
          ~capability=binding.capability,
          ~labelField=binding.labelField,
          ~ownerScope?,
          ~retiredScope?,
        ) {
        | Some(conn) => conn
        | None =>
          // Shapes listPage declines (search/searchPrefix/ids/backward) → run the
          // shared spec over the materialised model, which decodes Relay global
          // ids the same way every other door now does.
          let items = await binding.pushdowns.scanAll(~readModelName=rm)
          ReventlessCore.QueryDbListQuery.run(
            ~items,
            ~argsDict,
            ~capability=binding.capability,
            ~labelField=binding.labelField,
            ~ownerScope?,
            ~retiredScope?,
          )
        }
      }

    // Cross-table single-ID field resolver (@resolves). `binding` is the TARGET
    // binding (the handler looks it up by payload.target); the key comes from the
    // parent object (payload.source[sourceIdField]).
    | "resolveOne" =>
      let target = payload.target->Option.getOr(rm)
      let source = payload.source->Option.getOr(JSON.Encode.null)
      let key = source->argStr(payload.sourceIdField->Option.getOr(""))->Option.getOr("")
      let items = switch payload.targetIndex {
      | Some(ix) =>
        await binding.pushdowns.indexLookup(
          ~readModelName=target,
          payload.targetIndexIdField->Option.getOr(ix),
          key,
        )
      | None =>
        switch await binding.ops.load(key) {
        | Ok(items) => items
        | Error(_) => []
        }
      }
      // Optional target sort-key filter (source field or GraphQL arg).
      let filtered = switch (payload.sourceSubId, binding.subIdField) {
      | (Some({kind, name}), Some(subField)) =>
        let subVal =
          switch kind {
          | "arg" => payload.arguments->argStr(name)
          | _ => source->argStr(name)
          }->Option.getOr("")
        items->Array.filter(it => it->argStr(subField)->Option.getOr("") == subVal)
      | _ => items
      }
      if payload.multi->Option.getOr(false) {
        JSON.Encode.array(filtered)
      } else {
        switch filtered->Array.get(0) {
        | Some(item) => item
        | None => JSON.Encode.null
        }
      }

    // Cross-table batch field resolver (@resolvesMany). ids come from the parent
    // object (payload.source[sourceIdsField]); BatchGet the target by partition
    // key (missing ids drop out).
    | "resolveMany" =>
      let target = payload.target->Option.getOr(rm)
      let source = payload.source->Option.getOr(JSON.Encode.null)
      let ids = source->argStrs(payload.sourceIdsField->Option.getOr(""))
      JSON.Encode.array(await binding.pushdowns.byIds(~readModelName=target, ids))

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

// Relay node type → read-model-name map (B3.2c), populated at Lambda init from
// the deploy-time registerNodeType calls.
let nodeTypeMap: dict<string> = Dict.make()
let registerNodeType = (~typeName: string, ~readModelName: string): unit =>
  nodeTypeMap->Dict.set(typeName, readModelName)

// node(id: ID!) — decode the global id (base64 of `typeName:localId`, matching
// AppSync's nodeDecodeGlobalId), map typeName → read model, load by localId,
// return the item tagged with __typename and the original global id. Runs the
// target's authorization/interceptor. Self-contained (getById returns raw ids,
// so no encoding elsewhere is affected).
let handleNode = async (~payload: payload): JSON.t => {
  let globalId = payload.arguments->argStr("id")->Option.getOr("")
  let decoded = try atob(globalId) catch {
  | _ => ""
  }
  let colonIdx = decoded->String.indexOf(":")
  if colonIdx <= 0 {
    JSON.Encode.null
  } else {
    let typeName = decoded->String.slice(~start=0, ~end=colonIdx)
    let localId = decoded->String.slice(~start=colonIdx + 1, ~end=decoded->String.length)
    switch nodeTypeMap->Dict.get(typeName)->Option.flatMap(rm => bindings->Dict.get(rm)) {
    | Some(binding) =>
      switch await runInterceptor(~binding, ~payload) {
      | Deny(_) => JSON.Encode.null
      | Allow =>
        switch await binding.ops.load(localId) {
        | Ok(items) =>
          switch items->Array.get(0) {
          | Some(item) =>
            let obj = item->JSON.Decode.object->Option.getOr(Dict.make())->Dict.copy
            obj->Dict.set("__typename", JSON.Encode.string(typeName))
            obj->Dict.set("id", JSON.Encode.string(globalId))
            JSON.Encode.object(obj)
          | None => JSON.Encode.null
          }
        | Error(_) => JSON.Encode.null
        }
      }
    | None => JSON.Encode.null
    }
  }
}

let handler = async (payload: payload, _context) => {
  // node decodes its own target; the cross-table field resolvers dispatch against
  // the TARGET binding; everything else against the payload's own read model.
  let bindingKey = switch payload.kind {
  | "resolveOne" | "resolveMany" => payload.target->Option.getOr(payload.readModelName)
  | _ => payload.readModelName
  }
  switch payload.kind {
  | "node" => await handleNode(~payload)
  | _ =>
    switch bindings->Dict.get(bindingKey) {
    | Some(binding) =>
      await dispatch(~binding, ~lookupBinding=name => bindings->Dict.get(name), ~payload)
    | None =>
      JsError.throwWithMessage("PgQueryResolver: no binding registered for read model " ++ bindingKey)
    }
  }
}
