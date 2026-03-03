// Shared in-memory GraphQL server.
// Collects SDL fragments and resolver functions from CommandGeneratorResolvers_GraphQL
// (mutations) and QueryDbResolvers_GraphQL (queries) during Platform.Make().
// start() is called once after all components are built.

module YG = GraphqlYoga

// -- Resolver type alias ---------------------------------------------------

type resolverFn = YG.resolverFn

// -- Registry --------------------------------------------------------------

let mutationResolvers: ref<dict<resolverFn>> = ref(Dict.make())
let queryResolvers: ref<dict<resolverFn>> = ref(Dict.make())

let mutationFields: ref<array<string>> = ref([])
let queryFields: ref<array<string>> = ref([])

let registerMutations = (~sdlFields: array<string>, ~resolvers: dict<resolverFn>) => {
  mutationFields.contents = mutationFields.contents->Array.concat(sdlFields)
  resolvers->Dict.toArray->Array.forEach(((k, v)) => mutationResolvers.contents->Dict.set(k, v))
}

let registerQueries = (~sdlFields: array<string>, ~resolvers: dict<resolverFn>) => {
  queryFields.contents = queryFields.contents->Array.concat(sdlFields)
  resolvers->Dict.toArray->Array.forEach(((k, v)) => queryResolvers.contents->Dict.set(k, v))
}

// -- Server lifecycle ------------------------------------------------------

let activeServer: ref<option<YG.httpServer>> = ref(None)

let buildSdl = () => {
  let mutations =
    mutationFields.contents->Array.length > 0
      ? mutationFields.contents->Array.join("\n")
      : "  _noop: String"
  let queries =
    queryFields.contents->Array.length > 0
      ? queryFields.contents->Array.join("\n")
      : "  _noop: String"
  `type Query {
${queries}
}
type Mutation {
${mutations}
}`
}

let start = (~port: int=4000, ()) => {
  let resolvers = Dict.make()
  resolvers->Dict.set("Query", queryResolvers.contents)
  resolvers->Dict.set("Mutation", mutationResolvers.contents)
  let schema = YG.createSchema({"typeDefs": buildSdl(), "resolvers": resolvers})
  let yoga = YG.createYoga({"schema": schema, "graphiql": true, "logging": true, "maskedErrors": false})
  let server = YG.createServer(yoga)
  server->YG.listen(port, () =>
    Console.log(`[GraphQL] Listening on http://localhost:${port->Int.toString}/graphql`)
  )
  activeServer.contents = Some(server)
}

let stop = () =>
  switch activeServer.contents {
  | Some(server) =>
    server->YG.close(() => ())
    activeServer.contents = None
  | None => ()
  }

// Rebuild the server schema by stitching plugin fragments with registered resolvers.
// Extracts type definitions from all fragments, then uses buildSdl() for Query/Mutation
// (which matches the registered resolver field names from CommandGenerator/QueryDb builders).
// Stops the existing server and restarts with the new SDL.
let rebuildSchema = (
  ~baseFragment: Reventless.Plugin.apiSchemaFragment,
  ~pluginFragments: array<Reventless.Plugin.apiSchemaFragment>,
) => {
  stop()
  let allFragments = Array.concat([baseFragment], pluginFragments)
  let fragmentTypes =
    allFragments
    ->Array.flatMap(frag => ReventlessCore.GraphQL_Stitcher.decode(frag).types)
    ->Array.join("\n\n")
  let queriesMutationsSdl = buildSdl()
  let fullSdl =
    fragmentTypes->String.length > 0
      ? fragmentTypes ++ "\n\n" ++ queriesMutationsSdl
      : queriesMutationsSdl
  let resolvers = Dict.make()
  resolvers->Dict.set("Query", queryResolvers.contents)
  resolvers->Dict.set("Mutation", mutationResolvers.contents)
  let schema = YG.createSchema({"typeDefs": fullSdl, "resolvers": resolvers})
  let yoga = YG.createYoga({"schema": schema, "graphiql": true, "logging": true, "maskedErrors": false})
  let server = YG.createServer(yoga)
  server->YG.listen(4000, () =>
    Console.log("[GraphQL] Rebuilt schema - http://localhost:4000/graphql")
  )
  activeServer.contents = Some(server)
}

// Reset registry state (call between isolated test suites).
let reset = () => {
  mutationResolvers.contents = Dict.make()
  queryResolvers.contents = Dict.make()
  mutationFields.contents = []
  queryFields.contents = []
}
