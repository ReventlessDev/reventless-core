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

module Make = (Bus: InMemory_Bus.T) => {
  open ReventlessCore

  type api = unit
  type role = unit

  // -- Identity extraction from GraphQL context ---------------------------------
  // graphql-yoga provides { request: Request, ... } as the resolver context.
  // We read the X-Identity header (JSON-encoded Identity.t) and fall back to anonymous.

  @send external getHeader: ('headers, string) => Nullable.t<string> = "get"

  let extractIdentity = (ctx: JSON.t): Reventless.Identity.t => {
    try {
      let request = (ctx->Obj.magic)["request"]
      let headers = request["headers"]
      switch headers->getHeader("x-identity")->Nullable.toOption {
      | Some(json) => json->JSON.parseOrThrow->S.parseOrThrow(Reventless.Identity.schema)
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
      switch QueryDb_Callback.queryInterceptorHook.contents {
      | None => Allow
      | Some(interceptor) =>
        await interceptor(
          ~identity=extractIdentity(ctx),
          ~readModelName=name,
          ~args,
        )
      }
    }

    let cap = s => s->String.charAt(0)->String.toUpperCase ++ s->String.slice(~start=1)

    // Resolve query field names: check registry first, fall back to safe defaults.
    // Fallbacks use simple GraphQL built-in types to avoid referencing non-existent custom types.
    let registryEntry = Plugin_Helpers.queryFieldNamesRegistry.contents->Dict.get(name)
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

    // -- List query -------------------------------------------------------------
    let (listSdl, listResolver): (array<string>, GraphQL_ServerInstance.resolverFn) = if connectionSpec {
      // Relay Connection spec format
      let connectionTypeName = returnTypeName ++ "Connection"
      let sdl = [`  ${listQueryName}(first: Int, after: String, last: Int, before: String): ${connectionTypeName}!`]
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
            "totalCount": 0,
          })
        | Allow =>
          let items = switch Bus.getQueryDbStream(name) {
          | Some(makeStream) =>
            await makeStream()->Stream.runCollect->Effect.runPromise
          | None =>
            switch Bus.getQueryDbScan(name) {
            | Some(scanAll) => scanAll()
            | None => []
            }
          }
          let edges = items->Array.mapWithIndex((item, i) => {
            Obj.magic({"node": item, "cursor": Int.toString(i)})
          })
          let startCursor = edges->Array.get(0)->Option.map(_ => Int.toString(0))
          let endCursor = if edges->Array.length > 0 {
            Some(Int.toString(edges->Array.length - 1))
          } else {
            None
          }
          Obj.magic({
            "edges": edges,
            "pageInfo": {
              "hasNextPage": false,
              "hasPreviousPage": false,
              "startCursor": startCursor->Nullable.fromOption,
              "endCursor": endCursor->Nullable.fromOption,
            },
            "totalCount": items->Array.length,
          })
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
          let items = switch Bus.getQueryDbStream(name) {
          | Some(makeStream) =>
            await makeStream()->Stream.runCollect->Effect.runPromise
          | None =>
            switch Bus.getQueryDbScan(name) {
            | Some(scanAll) => scanAll()
            | None => []
            }
          }
          Obj.magic({"nextToken": Nullable.null, "scannedCount": items->Array.length, "items": items})
        }
      }
      (sdl, resolver)
    }
    let listResolvers = [(listQueryName, listResolver)]

    // -- By-id-list: {name}ById (only when subId configured) ------------------
    // Supports sort key filtering: prefix, from, to, eq, reverse, limit, nextToken.
    // Returns { items: [...], nextToken: String | null }.
    let byIdListSdl = switch subIdField {
    | Some(sf) =>
      let connectionTypeName = returnTypeName ++ "ByIdConnection"
      server.registerTypes(
        ~sdlTypes=[
          `type ${connectionTypeName} {\n  items: [${returnTypeName}!]!\n  nextToken: String\n}`,
        ],
      )
      [`  ${singleQueryName}ById(id: ID!, ${sf}: String, prefix: String, from: String, to: String, eq: String, reverse: Boolean, limit: Int, nextToken: String): ${connectionTypeName}!`]
    | None => []
    }
    let byIdListResolvers: array<(string, GraphQL_ServerInstance.resolverFn)> = switch subIdField {
    | Some(sf) =>
      let resolver: GraphQL_ServerInstance.resolverFn = async (_root, args, ctx) => {
        switch await runInterceptor(~ctx, ~args) {
        | Deny(_) => Obj.magic({"items": [], "nextToken": Nullable.null})
        | Allow =>
          let argsDict = args->JSON.Decode.object->Option.getOr(Dict.make())
          let id = argsDict->Dict.get("id")->Option.flatMap(JSON.Decode.string)->Option.getOr("")
          let filterPrefix = argsDict->Dict.get("prefix")->Option.flatMap(JSON.Decode.string)
          let filterFrom   = argsDict->Dict.get("from")->Option.flatMap(JSON.Decode.string)
          let filterTo     = argsDict->Dict.get("to")->Option.flatMap(JSON.Decode.string)
          let filterEq     = argsDict->Dict.get("eq")->Option.flatMap(JSON.Decode.string)
          let reverse      = argsDict->Dict.get("reverse")->Option.flatMap(JSON.Decode.bool)->Option.getOr(false)
          let limit        = argsDict->Dict.get("limit")->Option.flatMap(JSON.Decode.float)->Option.map(Float.toInt)
          let nextTokenStr = argsDict->Dict.get("nextToken")->Option.flatMap(JSON.Decode.string)
          let offset = nextTokenStr->Option.flatMap(s => Int.fromString(s))->Option.getOr(0)
          switch Bus.getQueryDb(name) {
          | Some(ops) =>
            let items =
              await ops.loadStream(id)
              ->Stream.runCollect
              ->Effect.catchAll(_ => Effect.succeed([]))
              ->Effect.runPromise
            let result = SortKey_Filter.apply(
              ~items,
              ~skField=sf,
              ~prefix=?filterPrefix,
              ~from=?filterFrom,
              ~to_=?filterTo,
              ~eq=?filterEq,
              ~reverse,
              ~limit=?limit,
              ~offset,
            )
            Obj.magic({"items": result.items, "nextToken": result.nextToken->Nullable.fromOption})
          | None => Obj.magic({"items": [], "nextToken": Nullable.null})
          }
        }
      }
      [(singleQueryName ++ "ById", resolver)]
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
        (resolverName, resolver)
      },
    )

    // -- Register all fields --------------------------------------------------
    let allSdl =
      [byIdSdl]->Array.concat(listSdl)->Array.concat(byIdListSdl)->Array.concat(indexSdlFields)

    let resolvers = Dict.make()
    resolvers->Dict.set(singleQueryName, byIdResolver)
    listResolvers->Array.forEach(((k, v)) => resolvers->Dict.set(k, v))
    byIdListResolvers->Array.forEach(((k, v)) => resolvers->Dict.set(k, v))
    indexResolvers->Array.forEach(((k, v)) => resolvers->Dict.set(k, v))
    server.registerQueries(~sdlFields=allSdl, ~resolvers)

    {
      resources: [],
      resourcesMaker: _ => [],
    }
  }

}
