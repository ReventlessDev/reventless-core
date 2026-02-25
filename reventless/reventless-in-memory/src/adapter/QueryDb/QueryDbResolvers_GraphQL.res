// GraphQL query resolvers for in-memory QueryDb.
// Make(Bus) functor: registers query fields into GraphQL_Server during component construction.
// Supports: getById, every{Name}, {name}ById (when subId), and {name}By{Index} per index.

module Make = (Bus: InMemory_Bus.T) => {
  open Reventless

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
    let queryName = name->String.charAt(0)->String.toLowerCase ++ name->String.slice(~start=1)

    // -- Main query: getById ---------------------------------------------------
    let byIdSdl = switch subIdField {
    | Some(sf) => `  ${queryName}(id: ID!, ${sf}: String): [String]`
    | None => `  ${queryName}(id: ID!): [String]`
    }
    let byIdResolver: GraphQL_Server.resolverFn = async (_root, args) => {
      let id = (args->Obj.magic: dict<string>)->Dict.get("id")->Option.getOr("")
      switch Bus.getQueryDb(name) {
      | Some(ops) =>
        let items = (await ops.load(id))->Result.mapOr([], v => v)
        items->JSON.Encode.array
      | None => []->JSON.Encode.array
      }
    }

    // -- List all: every{Name} ------------------------------------------------
    let everyName = "every" ++ name
    let everySdl = `  ${everyName}: [String]`
    let everyResolver: GraphQL_Server.resolverFn = async (_root, _args) => {
      switch Bus.getQueryDbScan(name) {
      | Some(scanAll) => scanAll()->JSON.Encode.array
      | None => []->JSON.Encode.array
      }
    }

    // -- By-id-list: {name}ById (only when subId configured) ------------------
    let byIdListSdl = switch subIdField {
    | Some(_) => [`  ${queryName}ById(id: ID!): [String]`]
    | None => []
    }
    let byIdListResolvers: array<(string, GraphQL_Server.resolverFn)> = switch subIdField {
    | Some(_) =>
      let resolver: GraphQL_Server.resolverFn = async (_root, args) => {
        let id = (args->Obj.magic: dict<string>)->Dict.get("id")->Option.getOr("")
        switch Bus.getQueryDb(name) {
        | Some(ops) =>
          let items = (await ops.load(id))->Result.mapOr([], v => v)
          items->JSON.Encode.array
        | None => []->JSON.Encode.array
        }
      }
      [(queryName ++ "ById", resolver)]
    | None => []
    }

    // -- Index queries: {name}By{Index} ---------------------------------------
    let indexSdlFields = indexes->Array.map((ic: ReventlessSpec.ReadModel.indexConfig) =>
      `  ${queryName}By${cap(ic.index)}(${ic.index}: String!): [String]`
    )
    let indexResolvers: array<(string, GraphQL_Server.resolverFn)> = indexes->Array.map(
      (ic: ReventlessSpec.ReadModel.indexConfig) => {
        let index = ic.index
        let resolverName = queryName ++ "By" ++ cap(index)
        let filterField = ic.idField->Option.getOr(index)
        let resolver: GraphQL_Server.resolverFn = async (_root, args) => {
          let value = (args->Obj.magic: dict<string>)->Dict.get(index)->Option.getOr("")
          switch Bus.getQueryDbScan(name) {
          | Some(scanAll) =>
            scanAll()
            ->Array.filter(item =>
              (item->Obj.magic: dict<string>)
              ->Dict.get(filterField)
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
      [byIdSdl, everySdl]->Array.concat(byIdListSdl)->Array.concat(indexSdlFields)

    let resolvers = Dict.make()
    resolvers->Dict.set(queryName, byIdResolver)
    resolvers->Dict.set(everyName, everyResolver)
    byIdListResolvers->Array.forEach(((k, v)) => resolvers->Dict.set(k, v))
    indexResolvers->Array.forEach(((k, v)) => resolvers->Dict.set(k, v))
    GraphQL_Server.registerQueries(~sdlFields=allSdl, ~resolvers)

    {
      resources: [],
      resourcesMaker: _ => [],
    }
  }
}
