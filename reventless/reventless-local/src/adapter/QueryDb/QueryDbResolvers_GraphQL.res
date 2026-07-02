// GraphQL query resolvers for in-memory QueryDb.
// Make(Bus) functor: registers query fields into the provided server during component construction.
// Supports: getById, list (when listFieldName provided), {name}ById (when subId), and {name}By{Index} per index.
//
// Query names are resolved from Plugin_Helpers.queryFieldNamesRegistry (populated by
// Plugin_Builder) to align with fragment SDL. Falls back to camelCase(name) for
// backward compatibility when no registry entry exists.
//
// Relay support is domain-only (platform QueryDbs pass relay=None):
//   - encodeGlobalId / decodeGlobalId for Relay global IDs
//   - node(id: ID!) resolution via registerNodeResolverCallback
//   - registerNodeType for the Relay Node type registry
// Platform admin views are not Relay-paginated so relay=None is correct for them.

// Relay support type — lifted to module level so Platform.res can construct a value
// without a functor application in type position (not supported in ReScript).
// Domain plugins pass Some(domainRelaySupport); platform plugins pass None.
type relaySupport = {
  encodeGlobalId: (~typeName: string, ~localId: string) => string,
  registerNodeType: (~typeName: string, ~queryDbName: string) => unit,
  registerNodeResolverCallback: DomainGraphQL_Server.nodeResolverCallback => unit,
  nodeTypeRegistry: ref<dict<string>>,
}

@val external btoa: string => string = "btoa"
@val external atob: string => string = "atob"

// Keyset-cursor helpers for the `{name}Items` (sub-id) connection — base64 of
// the sub-key value. The main connection list resolver's cursor logic now lives
// in `QueryDbListQuery`; these remain for the items resolver below.
let encodeCursor = (value: string): string => btoa(value)
let decodeCursor = (cursor: string): string => atob(cursor)

module Make = (Bus: LocalBus.T) => {
  open ReventlessCore

  type api = unit
  type role = unit

  // -- Identity extraction from GraphQL context ---------------------------------
  // graphql-yoga's `context` factory in DomainGraphQL_Server.buildAuthContext
  // runs LocalAuth.authenticate per request and attaches the resolved
  // `Identity.t` to `ctx.identity`. Fallback to anonymous only when ctx is
  // malformed.

  let extractIdentity = (ctx: JSON.t): Reventless.Identity.t => {
    try {
      switch (ctx->Obj.magic)["identity"]->Nullable.toOption {
      | Some(id) => (id: Reventless.Identity.t)
      | None => Reventless.Identity.anonymous
      }
    } catch {
    | _ => Reventless.Identity.anonymous
    }
  }

  // -- Module-level server and relay refs ------------------------------------
  // Set by Platform.res before component construction runs so the make function
  // can pick up the correct target server and relay support (mirrors AWS ~api pattern).
  let serverRef: ref<GraphQL_ServerInstance.t> = ref(DomainGraphQL_Server.asInterface)
  let relayRef: ref<option<relaySupport>> = ref(Some({
    encodeGlobalId: DomainGraphQL_Server.encodeGlobalId,
    registerNodeType: DomainGraphQL_Server.registerNodeType,
    registerNodeResolverCallback: DomainGraphQL_Server.registerNodeResolverCallback,
    nodeTypeRegistry: DomainGraphQL_Server.nodeTypeRegistry,
  }))

  let make: QueryDb_Adapter.resolversMaker<unit, unit> = (
    ~name,
    ~api as _,
    ~apiRole as _,
    ~dataSourceName as _,
    ~indexes,
    ~subIdField,
    ~idResolverConfigs as _,
    ~idsResolverConfigs as _,
    ~authorization,
    ~opts as _,
  ) => {
    // Read the active server and relay support from module-level refs set by Platform.res.
    // This mirrors how AWS adapters receive ~api from the hook; here the hook sets the refs
    // before calling make() so the values are available at registration time.
    let server = serverRef.contents
    let relay = relayRef.contents

    // Register the Relay node resolver callback once per QueryDb (domain only).
    // Scans all QueryDb instances to resolve node(id: ID!) queries.
    switch relay {
    | Some(r) =>
      r.registerNodeResolverCallback(async (~typeName, ~localId) => {
        let queryDbName = switch r.nodeTypeRegistry.contents->Dict.get(typeName) {
        | Some(n) => n
        | None => typeName
        }
        switch Bus.getQueryDb(queryDbName) {
        | Some(ops) =>
          let items =
            await ops.loadStream(localId)
            ->Stream.runCollect
            ->Effect.catchAll(_ => Effect.succeed([]))
            ->Effect.runPromise
          switch items->Array.get(0) {
          | Some(item) =>
            let obj = item->JSON.Decode.object->Option.getOr(Dict.make())
            obj->Dict.set("__typename", JSON.Encode.string(typeName))
            obj->Dict.set("id", r.encodeGlobalId(~typeName, ~localId)->JSON.Encode.string)
            Some(JSON.Encode.object(obj))
          | None => None
          }
        | None => None
        }
      })
    | None => ()
    }

    let runInterceptor = async (~ctx, ~args): QueryDb_Callback.interceptResult => {
      let identity = extractIdentity(ctx)
      // Spec-level authorization runs first; failures short-circuit before
      // the user-supplied interceptor (mirrors mutation enforcement).
      if !Reventless.Authorization.isAllowed(authorization, identity) {
        Deny("Forbidden")
      } else {
        switch QueryDb_Callback.queryInterceptorHook.contents {
        | None => Allow
        | Some(interceptor) => await interceptor(~identity, ~readModelName=name, ~args)
        }
      }
    }

    let cap = s => s->String.charAt(0)->String.toUpperCase ++ s->String.slice(~start=1)

    // Resolve query field names: check registry first, fall back to safe defaults.
    // Fallbacks use simple GraphQL built-in types to avoid referencing non-existent custom types.
    let registryEntry = Plugin_Helpers.queryFieldNamesRegistry->Dict.get(name)
    let singleQueryName = switch registryEntry {
    | Some({singleFieldName}) => singleFieldName
    | None => name->String.charAt(0)->String.toLowerCase ++ name->String.slice(~start=1)
    }
    let listQueryName = switch registryEntry {
    | Some({listFieldName}) => listFieldName
    | None => name ++ "s"
    }
    let returnTypeName = switch registryEntry {
    | Some({returnTypeName: rt}) => rt
    | None => "String"
    }
    let pluralTypeName = switch registryEntry {
    | Some({pluralTypeName}) => pluralTypeName
    | None => "[String]"
    }

    // Resolve includeIdParam flag from registry (defaults to true for ReadModels)
    let includeIdParam = switch registryEntry {
    | Some({includeIdParam}) => includeIdParam
    | None => true
    }

    // Resolve connectionSpec flag from registry (defaults to true)
    let connectionSpec = switch registryEntry {
    | Some({connectionSpec}) => connectionSpec
    | None => true
    }

    // Register this entity type in the Relay Node type registry (domain only).
    if includeIdParam {
      switch relay {
      | Some(r) => r.registerNodeType(~typeName=returnTypeName, ~queryDbName=name)
      | None => ()
      }
    }

    let encodeId = switch relay {
    | Some(r) => (~typeName, ~localId) => r.encodeGlobalId(~typeName, ~localId)
    | None => (~typeName as _, ~localId) => localId
    }

    // -- Main query: getById ---------------------------------------------------
    let byIdSdl = if includeIdParam {
      switch subIdField {
      | Some(sf) => `  ${singleQueryName}(id: ID!, ${sf}: String): ${returnTypeName}`
      | None => `  ${singleQueryName}(id: ID!): ${returnTypeName}`
      }
    } else {
      `  ${singleQueryName}: ${returnTypeName}`
    }
    let byIdResolver: GraphQL_ServerInstance.resolverFn = async (_root, args, ctx) => {
      switch await runInterceptor(~ctx, ~args) {
      | Deny(_) => JSON.Encode.null
      | Allow =>
        let id =
          args->JSON.Decode.object->Option.flatMap(d => d->Dict.get("id"))->Option.flatMap(JSON.Decode.string)->Option.getOr("")
        switch Bus.getQueryDb(name) {
        | Some(ops) =>
          let items =
            await ops.loadStream(id)
            ->Stream.runCollect
            ->Effect.catchAll(_ => Effect.succeed([]))
            ->Effect.runPromise
          switch items->Array.get(0) {
          | Some(item) =>
            if includeIdParam {
              let obj = item->JSON.Decode.object->Option.getOr(Dict.make())
              obj->Dict.set("id", encodeId(~typeName=returnTypeName, ~localId=id)->JSON.Encode.string)
              JSON.Encode.object(obj)
            } else {
              item
            }
          | None => JSON.Encode.null
          }
        | None => JSON.Encode.null
        }
      }
    }

    // -- Batched-by-ids query: {listFieldName}ByIds ---------------------------
    // Mirrors the AppSync BatchGetItem resolver. Single-key projections only
    // (subIdField=None) — matches the SDL emitted by FragmentGenerator. Missing
    // ids drop out of the response (no cardinality preservation), matching
    // BatchGetItem semantics.
    let byIdsSdl = if includeIdParam && subIdField === None {
      [GraphQL_FragmentGenerator.deriveByIdsQueryField(~listFieldName=listQueryName, ~returnTypeName)]
    } else {
      []
    }
    let byIdsResolverEntry: option<(string, GraphQL_ServerInstance.resolverFn)> =
      if includeIdParam && subIdField === None {
        let resolver: GraphQL_ServerInstance.resolverFn = async (_root, args, ctx) => {
          switch await runInterceptor(~ctx, ~args) {
          | Deny(_) => []->JSON.Encode.array
          | Allow =>
            let ids =
              args
              ->JSON.Decode.object
              ->Option.flatMap(d => d->Dict.get("ids"))
              ->Option.flatMap(JSON.Decode.array)
              ->Option.getOr([])
              ->Array.filterMap(JSON.Decode.string)
            switch Bus.getQueryDb(name) {
            | Some(ops) =>
              let loaded = await ids->Array.map(id =>
                ops.loadStream(id)
                ->Stream.runCollect
                ->Effect.catchAll(_ => Effect.succeed([]))
                ->Effect.runPromise
                ->Promise.thenResolve(items => (id, items->Array.get(0)))
              )->Promise.all
              loaded
              ->Array.filterMap(((id, opt)) =>
                opt->Option.map(item => {
                  let obj = item->JSON.Decode.object->Option.getOr(Dict.make())
                  obj->Dict.set(
                    "id",
                    encodeId(~typeName=returnTypeName, ~localId=id)->JSON.Encode.string,
                  )
                  JSON.Encode.object(obj)
                })
              )
              ->JSON.Encode.array
            | None => []->JSON.Encode.array
            }
          }
        }
        Some((listQueryName ++ "ByIds", resolver))
      } else {
        None
      }

    // Look up labelField from registry (Phase 3). Used by list-query filter.search /
    // searchPrefix to target the entity's human-readable column without per-entity
    // resolver wiring. Falls back to "id" so filtering still works on entities
    // without a @displayName annotation (match on the partition key).
    let labelField = switch registryEntry {
    | Some({labelField: ?lf}) => lf->Option.getOr("id")
    | None => "id"
    }

    // -- List query -------------------------------------------------------------
    // Look up the registered state schema (populated alongside queryFieldNamesRegistry)
    // so the resolver derives the same serverCapability the FragmentGenerator emitted.
    let stateSchemaOpt = Plugin_Helpers.stateSchemaRegistry->Dict.get(name)
    let capability = switch stateSchemaOpt {
    | Some(s) => GraphQL_FragmentGenerator.deriveServerCapability(s)
    | None => GraphQL_FragmentGenerator.emptyCapability
    }

    // Materialise the whole read model (stream preferred, scan fallback). The
    // fallback path for list queries when no backend push-down is available.
    let fetchAllItems = async (): array<JSON.t> =>
      switch Bus.getQueryDbStream(name) {
      | Some(makeStream) => await makeStream()->Stream.runCollect->Effect.runPromise
      | None =>
        switch Bus.getQueryDbScan(name) {
        | Some(scanAll) => scanAll()
        | None => []
        }
      }

    let (listSdl, listResolver): (array<string>, GraphQL_ServerInstance.resolverFn) = if connectionSpec {
      // Relay Connection spec format
      let filterTypeName = returnTypeName ++ "Filter"
      let orderByTypes = GraphQL_FragmentGenerator.deriveConnectionOrderByType(
        ~singularTypeName=returnTypeName,
        ~capability,
      )
      let hasOrderBy = orderByTypes->Array.length > 0
      let typesToRegister = [
        GraphQL_FragmentGenerator.deriveConnectionFilterType(~filterTypeName, ~capability),
      ]->Array.concat(orderByTypes)
      server.registerTypes(~sdlTypes=typesToRegister)
      let sdl = [
        GraphQL_FragmentGenerator.deriveConnectionQueryField(
          ~listFieldName=listQueryName,
          ~singularTypeName=returnTypeName,
          ~filterTypeName,
          ~hasOrderBy,
        ),
      ]
      let resolver: GraphQL_ServerInstance.resolverFn = async (_root, args, ctx) => {
        switch await runInterceptor(~ctx, ~args) {
        | Deny(_) =>
          Obj.magic({
            "edges": [],
            "pageInfo": {
              "hasNextPage": false,
              "hasPreviousPage": false,
              "startCursor": Nullable.null,
              "endCursor": Nullable.null,
            },
          })
        | Allow =>
          let argsDict = args->JSON.Decode.object->Option.getOr(Dict.make())
          // Prefer a backend list push-down (SQLite builds json_extract predicates
          // + ORDER BY … LIMIT so it never materialises the whole read model). When
          // the backend can't serve this query shape it returns None and we fall
          // back to materialising the full model and running the shared
          // `QueryDbListQuery` spec over it (the same code the in-memory backend and
          // the push-down are tested against).
          let decodeLocalId = id =>
            DomainGraphQL_Server.decodeGlobalId(id)->Option.map(((_, lid)) => lid)
          switch Bus.getQueryDbListPage(name) {
          | Some(listPage) =>
            switch listPage(~argsDict, ~capability, ~labelField) {
            | Some(conn) => conn
            | None =>
              let items = await fetchAllItems()
              QueryDbListQuery.run(~items, ~argsDict, ~capability, ~labelField, ~decodeLocalId)
            }
          | None =>
            let items = await fetchAllItems()
            QueryDbListQuery.run(~items, ~argsDict, ~capability, ~labelField, ~decodeLocalId)
          }
        }
      }
      (sdl, resolver)
    } else {
      // Legacy AppSync-style format
      let sdl = [`  ${listQueryName}(nextToken: String, limit: Int): ${pluralTypeName}!`]
      let resolver: GraphQL_ServerInstance.resolverFn = async (_root, args, ctx) => {
        switch await runInterceptor(~ctx, ~args) {
        | Deny(_) => Obj.magic({"nextToken": Nullable.null, "scannedCount": 0, "items": []})
        | Allow =>
          let items = await fetchAllItems()
          Obj.magic({"nextToken": Nullable.null, "scannedCount": items->Array.length, "items": items})
        }
      }
      (sdl, resolver)
    }
    let listResolvers = [(listQueryName, listResolver)]

    // -- Items query: {name}Items (only when subId configured) -----------------
    // Relay Connection response. Accepts `filter` input object + first/after/last/before.
    // Cursor is base64 of the sort key value (keyset pagination — see module-level
    // `encodeCursor` / `decodeCursor` helpers).
    let itemsSdl = switch subIdField {
    | Some(_sf) =>
      let filterTypeName = returnTypeName ++ "ItemsFilter"
      let connectionTypeName = returnTypeName ++ "Connection"
      server.registerTypes(
        ~sdlTypes=[
          `input ${filterTypeName} {\n  prefix: String\n  from: String\n  to: String\n  eq: String\n  order: SortOrder\n}`,
        ],
      )
      [`  ${singleQueryName}Items(id: ID!, filter: ${filterTypeName}, first: Int, after: String, last: Int, before: String): ${connectionTypeName}!`]
    | None => []
    }
    let itemsResolvers: array<(string, GraphQL_ServerInstance.resolverFn)> = switch subIdField {
    | Some(sf) =>
      let resolver: GraphQL_ServerInstance.resolverFn = async (_root, args, ctx) => {
        let emptyConn = Obj.magic({
          "edges": [],
          "pageInfo": {
            "hasNextPage": false,
            "hasPreviousPage": false,
            "startCursor": Nullable.null,
            "endCursor": Nullable.null,
          },
        })
        switch await runInterceptor(~ctx, ~args) {
        | Deny(_) => emptyConn
        | Allow =>
          let argsDict = args->JSON.Decode.object->Option.getOr(Dict.make())
          let id = argsDict->Dict.get("id")->Option.flatMap(JSON.Decode.string)->Option.getOr("")
          let filterDict =
            argsDict->Dict.get("filter")->Option.flatMap(JSON.Decode.object)->Option.getOr(Dict.make())
          let filterPrefix = filterDict->Dict.get("prefix")->Option.flatMap(JSON.Decode.string)
          let filterFrom   = filterDict->Dict.get("from")->Option.flatMap(JSON.Decode.string)
          let filterTo     = filterDict->Dict.get("to")->Option.flatMap(JSON.Decode.string)
          let filterEq     = filterDict->Dict.get("eq")->Option.flatMap(JSON.Decode.string)
          let orderDesc    = filterDict->Dict.get("order")->Option.flatMap(JSON.Decode.string)->Option.map(o => o == "DESC")->Option.getOr(false)
          let first        = argsDict->Dict.get("first")->Option.flatMap(JSON.Decode.float)->Option.map(Float.toInt)
          let after        = argsDict->Dict.get("after")->Option.flatMap(JSON.Decode.string)
          let last         = argsDict->Dict.get("last")->Option.flatMap(JSON.Decode.float)->Option.map(Float.toInt)
          let before       = argsDict->Dict.get("before")->Option.flatMap(JSON.Decode.string)
          let isBackward   = last->Option.isSome

          switch Bus.getQueryDb(name) {
          | None => emptyConn
          | Some(ops) =>
            let allItems =
              await ops.loadStream(id)
              ->Stream.runCollect
              ->Effect.catchAll(_ => Effect.succeed([]))
              ->Effect.runPromise

            // Cursor-keyed filtering: exclude items on the cursor side of the boundary
            let cursorFiltered = if isBackward {
              switch before->Option.map(decodeCursor) {
              | Some(beforeKey) =>
                allItems->Array.filter(item =>
                  item->JSON.Decode.object->Option.flatMap(d => d->Dict.get(sf))->Option.flatMap(JSON.Decode.string)->Option.map(v => v < beforeKey)->Option.getOr(false)
                )
              | None => allItems
              }
            } else {
              switch after->Option.map(decodeCursor) {
              | Some(afterKey) =>
                allItems->Array.filter(item =>
                  item->JSON.Decode.object->Option.flatMap(d => d->Dict.get(sf))->Option.flatMap(JSON.Decode.string)->Option.map(v => v > afterKey)->Option.getOr(false)
                )
              | None => allItems
              }
            }

            // Apply SortKey_Filter for prefix/from/to/eq
            let filtered = SortKey_Filter.apply(
              ~items=cursorFiltered,
              ~skField=sf,
              ~prefix=?filterPrefix,
              ~from=?filterFrom,
              ~to_=?filterTo,
              ~eq=?filterEq,
              ~reverse=if isBackward { !orderDesc } else { orderDesc },
              ~offset=0,
            ).items

            // For backward pagination flip to logical order after taking
            let (pageItems, hasMore) = switch (isBackward, last, first) {
            | (true, Some(n), _) =>
              let take = n + 1
              let taken = filtered->Array.slice(~start=0, ~end=take)
              let hasMore = taken->Array.length > n
              let result = taken->Array.slice(~start=0, ~end=n)->Array.toReversed
              (result, hasMore)
            | (_, _, Some(n)) =>
              let take = n + 1
              let taken = filtered->Array.slice(~start=0, ~end=take)
              let hasMore = taken->Array.length > n
              (taken->Array.slice(~start=0, ~end=n), hasMore)
            | _ => (filtered, false)
            }

            let getSkValue = item =>
              item->JSON.Decode.object->Option.flatMap(d => d->Dict.get(sf))->Option.flatMap(JSON.Decode.string)->Option.getOr("")

            let edges = pageItems->Array.map(item =>
              Obj.magic({"node": item, "cursor": encodeCursor(getSkValue(item))})
            )
            let startCursor = pageItems->Array.get(0)->Option.map(item => encodeCursor(getSkValue(item)))
            let endCursor   = pageItems->Array.get(pageItems->Array.length - 1)->Option.map(item => encodeCursor(getSkValue(item)))

            Obj.magic({
              "edges": edges,
              "pageInfo": {
                "hasNextPage": !isBackward && hasMore,
                "hasPreviousPage": isBackward && hasMore,
                "startCursor": startCursor->Nullable.fromOption,
                "endCursor": endCursor->Nullable.fromOption,
              },
            })
          }
        }
      }
      [(singleQueryName ++ "Items", resolver)]
    | None => []
    }

    // -- Index queries: {name}By{Index} ---------------------------------------
    let indexSdlFields = indexes->Array.map((ic: Reventless.ReadModel.indexConfig) =>
      `  ${singleQueryName}By${cap(ic.index)}(${ic.index}: String!): [String]`
    )
    let indexResolvers: array<(string, GraphQL_ServerInstance.resolverFn)> = indexes->Array.map(
      (ic: Reventless.ReadModel.indexConfig) => {
        let index = ic.index
        let resolverName = singleQueryName ++ "By" ++ cap(index)
        let filterField = ic.idField->Option.getOr(index)
        let resolver: GraphQL_ServerInstance.resolverFn = async (_root, args, ctx) => {
          switch await runInterceptor(~ctx, ~args) {
          | Deny(_) => []->JSON.Encode.array
          | Allow =>
            let value =
              args->JSON.Decode.object->Option.flatMap(d => d->Dict.get(index))->Option.flatMap(JSON.Decode.string)->Option.getOr("")
            // Prefer the pushed-down equality lookup (SQLite rides the GSI index;
            // in-memory reuses its lazy snapshot). Fall back to scan+filter only
            // if no lookup is registered for this QueryDb.
            switch Bus.getQueryDbIndexLookup(name) {
            | Some(lookup) => lookup(filterField, value)->JSON.Encode.array
            | None =>
              switch Bus.getQueryDbScan(name) {
              | Some(scanAll) =>
                scanAll()
                ->Array.filter(item =>
                  item
                  ->JSON.Decode.object
                  ->Option.flatMap(d => d->Dict.get(filterField))
                  ->Option.flatMap(JSON.Decode.string)
                  ->Option.map(v => v == value)
                  ->Option.getOr(false)
                )
                ->JSON.Encode.array
              | None => []->JSON.Encode.array
              }
            }
          }
        }
        (resolverName, resolver)
      },
    )

    // -- Register all fields --------------------------------------------------
    let allSdl =
      [byIdSdl]
      ->Array.concat(byIdsSdl)
      ->Array.concat(listSdl)
      ->Array.concat(itemsSdl)
      ->Array.concat(indexSdlFields)

    let resolvers = Dict.make()
    resolvers->Dict.set(singleQueryName, byIdResolver)
    byIdsResolverEntry->Option.forEach(((k, v)) => resolvers->Dict.set(k, v))
    listResolvers->Array.forEach(((k, v)) => resolvers->Dict.set(k, v))
    itemsResolvers->Array.forEach(((k, v)) => resolvers->Dict.set(k, v))
    indexResolvers->Array.forEach(((k, v)) => resolvers->Dict.set(k, v))
    server.registerQueries(~sdlFields=allSdl, ~resolvers)

    {
      resources: [],
      resourcesMaker: _ => [],
    }
  }

}
