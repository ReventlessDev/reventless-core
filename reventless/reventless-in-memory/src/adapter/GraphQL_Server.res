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

@val external processEnv: dict<string> = "process.env"
let debug = processEnv->Dict.get("GRAPHQL_DEBUG")->Option.isSome

let activeServer: ref<option<YG.httpServer>> = ref(None)
let activeSchema: ref<option<YG.schema>> = ref(None)
let lastFullSdl: ref<option<string>> = ref(None)

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
  let sdl = buildSdl()
  lastFullSdl.contents = Some(sdl)
  let schema = YG.createSchema({"typeDefs": sdl, "resolvers": resolvers})
  activeSchema.contents = Some(schema)
  let yoga = YG.createYoga({"schema": schema, "graphiql": true, "logging": debug, "maskedErrors": !debug})
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
    activeSchema.contents = None
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
  lastFullSdl.contents = Some(fullSdl)
  let resolvers = Dict.make()
  resolvers->Dict.set("Query", queryResolvers.contents)
  resolvers->Dict.set("Mutation", mutationResolvers.contents)
  let schema = YG.createSchema({"typeDefs": fullSdl, "resolvers": resolvers})
  activeSchema.contents = Some(schema)
  let yoga = YG.createYoga({"schema": schema, "graphiql": true, "logging": debug, "maskedErrors": !debug})
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
  activeSchema.contents = None
  lastFullSdl.contents = None
}

// -- Inspection & diagnostics ---------------------------------------------

let getRegisteredSdl = () => buildSdl()

type resolverNames = {mutations: array<string>, queries: array<string>}

let getRegisteredResolverNames = (): resolverNames => {
  mutations: mutationResolvers.contents->Dict.keysToArray,
  queries: queryResolvers.contents->Dict.keysToArray,
}

let getFullSdl = () => lastFullSdl.contents

let getSchema = () => activeSchema.contents

let getLiveSdl = () => activeSchema.contents->Option.map(YG.printSchema)

let printLiveSdl = () =>
  switch getLiveSdl() {
  | Some(sdl) =>
    Console.log("[GraphQL] Live SDL:")
    Console.log(sdl)
  | None => Console.log("[GraphQL] No active schema")
  }

type diagnostics = {
  registeredMutationFields: array<string>,
  registeredQueryFields: array<string>,
  registeredMutationResolvers: array<string>,
  registeredQueryResolvers: array<string>,
  sdlMutationCount: int,
  sdlQueryCount: int,
  resolverMutationCount: int,
  resolverQueryCount: int,
  mismatches: array<string>,
  fullSdl: option<string>,
  serverRunning: bool,
}

let extractFieldName = (sdlField: string): string => {
  let trimmed = sdlField->String.trim
  trimmed
  ->String.split("(")
  ->Array.get(0)
  ->Option.getOr("")
  ->String.trim
  ->String.split(":")
  ->Array.get(0)
  ->Option.getOr("")
  ->String.trim
}

let diagnostics = (): diagnostics => {
  let mutFieldNames =
    mutationFields.contents->Array.map(extractFieldName)->Array.filter(n => n != "_noop")
  let queryFieldNames =
    queryFields.contents->Array.map(extractFieldName)->Array.filter(n => n != "_noop")
  let mutResolverNames = mutationResolvers.contents->Dict.keysToArray
  let queryResolverNames = queryResolvers.contents->Dict.keysToArray

  let mismatches: array<string> = []

  // SDL fields without resolvers
  let mutResolverSet = Set.fromArray(mutResolverNames)
  mutFieldNames->Array.forEach(name =>
    if !(mutResolverSet->Set.has(name)) {
      mismatches->Array.push(`Mutation "${name}": SDL field but no resolver`)
    }
  )
  let queryResolverSet = Set.fromArray(queryResolverNames)
  queryFieldNames->Array.forEach(name =>
    if !(queryResolverSet->Set.has(name)) {
      mismatches->Array.push(`Query "${name}": SDL field but no resolver`)
    }
  )

  // Resolvers without SDL fields
  let mutFieldSet = Set.fromArray(mutFieldNames)
  mutResolverNames->Array.forEach(name =>
    if !(mutFieldSet->Set.has(name)) {
      mismatches->Array.push(`Mutation "${name}": resolver but no SDL field`)
    }
  )
  let queryFieldSet = Set.fromArray(queryFieldNames)
  queryResolverNames->Array.forEach(name =>
    if !(queryFieldSet->Set.has(name)) {
      mismatches->Array.push(`Query "${name}": resolver but no SDL field`)
    }
  )

  {
    registeredMutationFields: mutFieldNames,
    registeredQueryFields: queryFieldNames,
    registeredMutationResolvers: mutResolverNames,
    registeredQueryResolvers: queryResolverNames,
    sdlMutationCount: mutFieldNames->Array.length,
    sdlQueryCount: queryFieldNames->Array.length,
    resolverMutationCount: mutResolverNames->Array.length,
    resolverQueryCount: queryResolverNames->Array.length,
    mismatches,
    fullSdl: lastFullSdl.contents,
    serverRunning: activeServer.contents->Option.isSome,
  }
}

let printDiagnostics = () => {
  let d = diagnostics()
  Console.log("[GraphQL Diagnostics]")
  Console.log(
    `  Mutations: ${d.sdlMutationCount->Int.toString} SDL fields, ${d.resolverMutationCount->Int.toString} resolvers`,
  )
  d.registeredMutationFields->Array.forEach(f => Console.log(`    SDL: ${f}`))
  d.registeredMutationResolvers->Array.forEach(r => Console.log(`    Resolver: ${r}`))
  Console.log(
    `  Queries: ${d.sdlQueryCount->Int.toString} SDL fields, ${d.resolverQueryCount->Int.toString} resolvers`,
  )
  d.registeredQueryFields->Array.forEach(f => Console.log(`    SDL: ${f}`))
  d.registeredQueryResolvers->Array.forEach(r => Console.log(`    Resolver: ${r}`))
  if d.mismatches->Array.length > 0 {
    Console.log(`  Mismatches (${d.mismatches->Array.length->Int.toString}):`)
    d.mismatches->Array.forEach(m => Console.log(`    ⚠ ${m}`))
  } else {
    Console.log("  No mismatches")
  }
  Console.log(`  Server running: ${d.serverRunning ? "yes" : "no"}`)
  switch d.fullSdl {
  | Some(sdl) =>
    Console.log("\n--- Full SDL ---")
    Console.log(sdl)
    Console.log("--- End ---")
  | None => Console.log("  No SDL recorded")
  }
}
