// GraphQL query resolvers for in-memory QueryDb.
// Make(Bus) functor: registers query fields into GraphQL_Server during component construction.
// Supports: getById, list (when listFieldName provided), {name}ById (when subId), and {name}By{Index} per index.
//
// Query names are resolved from Plugin_Helpers.queryFieldNamesRegistry (populated by
// Plugin_Builder) to align with fragment SDL. Falls back to camelCase(name) for
// backward compatibility when no registry entry exists.

module Make = (Bus: InMemory_Bus.T) => {
  open ReventlessCore

  type api = unit
  type role = unit

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
    let cap = s => s->String.charAt(0)->String.toUpperCase ++ s->String.slice(~start=1)

    // Resolve query field names: check registry first, fall back to legacy camelCase
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
    | None => name ++ "s"
    }

    // -- Main query: getById ---------------------------------------------------
    let byIdSdl = switch subIdField {
    | Some(sf) => `  ${singleQueryName}(id: ID!, ${sf}: String): ${returnTypeName}`
    | None => `  ${singleQueryName}(id: ID!): ${returnTypeName}`
    }
    let byIdResolver: GraphQL_Server.resolverFn = async (_root, args) => {
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
        | Some(item) => item
        | None => JSON.Encode.null
        }
      | None => JSON.Encode.null
      }
    }

    // -- List query -------------------------------------------------------------
    let listSdl = [`  ${listQueryName}(nextToken: String, limit: Int): ${pluralTypeName}!`]
    let listResolver: GraphQL_Server.resolverFn = async (_root, _args) => {
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
    let listResolvers = [(listQueryName, listResolver)]

    // -- By-id-list: {name}ById (only when subId configured) ------------------
    let byIdListSdl = switch subIdField {
    | Some(_) => [`  ${singleQueryName}ById(id: ID!): [String]`]
    | None => []
    }
    let byIdListResolvers: array<(string, GraphQL_Server.resolverFn)> = switch subIdField {
    | Some(_) =>
      let resolver: GraphQL_Server.resolverFn = async (_root, args) => {
        let id =
          args->JSON.Decode.object->Option.flatMap(d => d->Dict.get("id"))->Option.flatMap(JSON.Decode.string)->Option.getOr("")
        switch Bus.getQueryDb(name) {
        | Some(ops) =>
          let items =
            await ops.loadStream(id)
            ->Stream.runCollect
            ->Effect.catchAll(_ => Effect.succeed([]))
            ->Effect.runPromise
          items->JSON.Encode.array
        | None => []->JSON.Encode.array
        }
      }
      [(singleQueryName ++ "ById", resolver)]
    | None => []
    }

    // -- Index queries: {name}By{Index} ---------------------------------------
    let indexSdlFields = indexes->Array.map((ic: Reventless.ReadModel.indexConfig) =>
      `  ${singleQueryName}By${cap(ic.index)}(${ic.index}: String!): [String]`
    )
    let indexResolvers: array<(string, GraphQL_Server.resolverFn)> = indexes->Array.map(
      (ic: Reventless.ReadModel.indexConfig) => {
        let index = ic.index
        let resolverName = singleQueryName ++ "By" ++ cap(index)
        let filterField = ic.idField->Option.getOr(index)
        let resolver: GraphQL_Server.resolverFn = async (_root, args) => {
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
    GraphQL_Server.registerQueries(~sdlFields=allSdl, ~resolvers)

    {
      resources: [],
      resourcesMaker: _ => [],
    }
  }
}
