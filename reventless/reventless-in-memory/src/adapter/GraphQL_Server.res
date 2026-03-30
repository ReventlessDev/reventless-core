// Shared in-memory GraphQL server.
// Collects SDL fragments and resolver functions from CommandGeneratorResolvers_GraphQL
// (mutations) and QueryDbResolvers_GraphQL (queries) during Platform.Make().
// start() is called once after all components are built.

module YG = GraphqlYoga

let log = ReventlessCore.Logger.fromEnv()

// -- Resolver type alias ---------------------------------------------------

type resolverFn = YG.resolverFn

// -- Registry --------------------------------------------------------------

let mutationResolvers: ref<dict<resolverFn>> = ref(Dict.make())
let queryResolvers: ref<dict<resolverFn>> = ref(Dict.make())

let mutationFields: ref<array<string>> = ref([])
let queryFields: ref<array<string>> = ref([])
let typeDefinitions: ref<array<string>> = ref([])

let registerMutations = (~sdlFields: array<string>, ~resolvers: dict<resolverFn>) => {
  mutationFields.contents = mutationFields.contents->Array.concat(sdlFields)
  resolvers->Dict.toArray->Array.forEach(((k, v)) => mutationResolvers.contents->Dict.set(k, v))
}

let registerQueries = (~sdlFields: array<string>, ~resolvers: dict<resolverFn>) => {
  queryFields.contents = queryFields.contents->Array.concat(sdlFields)
  resolvers->Dict.toArray->Array.forEach(((k, v)) => queryResolvers.contents->Dict.set(k, v))
}

/** Look up a registered mutation resolver by field name (used by MCP_Server). */
let getMutationResolver = (fieldName: string): option<resolverFn> =>
  mutationResolvers.contents->Dict.get(fieldName)

/** Look up a registered query resolver by field name (used by MCP_Server). */
let getQueryResolver = (fieldName: string): option<resolverFn> =>
  queryResolvers.contents->Dict.get(fieldName)

let registerTypes = (~sdlTypes: array<string>) => {
  typeDefinitions.contents = typeDefinitions.contents->Array.concat(sdlTypes)
}

// -- Server lifecycle ------------------------------------------------------

@val external processEnv: dict<string> = "process.env"
let debug = processEnv->Dict.get("GRAPHQL_DEBUG")->Option.isSome

let activeServer: ref<option<YG.httpServer>> = ref(None)
let activeSchema: ref<option<YG.schema>> = ref(None)
let lastFullSdl: ref<option<string>> = ref(None)

let buildSdl = () => {
  let typesSdl = typeDefinitions.contents->Array.length > 0
    ? typeDefinitions.contents->Array.join("\n\n")
    : ""
  let mutations =
    mutationFields.contents->Array.length > 0
      ? mutationFields.contents->Array.join("\n")
      : "  _noop: String"
  let queries =
    queryFields.contents->Array.length > 0
      ? queryFields.contents->Array.join("\n")
      : "  _noop: String"
  let queriesMutationsSdl = `type Query {
${queries}
}
type Mutation {
${mutations}
}`
  typesSdl->String.length > 0
    ? typesSdl ++ "\n\n" ++ queriesMutationsSdl
    : queriesMutationsSdl
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
    log.info(~comp="GraphQL", `listening on http://localhost:${port->Int.toString}/graphql`)
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
// Merges any additional type definitions from fragments into the type registry,
// then uses buildSdl() which includes types + Query + Mutation.
// Stops the existing server and restarts with the new SDL.
let rebuildSchema = (
  ~baseFragment: Reventless.Plugin.apiSchemaFragment,
  ~pluginFragments: array<Reventless.Plugin.apiSchemaFragment>,
) => {
  stop()
  // Merge any fragment types not already registered via the hook
  let allFragments = Array.concat([baseFragment], pluginFragments)
  let fragmentTypes = allFragments->Array.flatMap(frag => ReventlessCore.GraphQL_Stitcher.decode(frag).types)
  let existingNames = Set.fromArray(typeDefinitions.contents->Array.map(ReventlessCore.GraphQL_Stitcher.extractLeadingName))
  fragmentTypes->Array.forEach(typeDef => {
    let name = ReventlessCore.GraphQL_Stitcher.extractLeadingName(typeDef)
    if !(existingNames->Set.has(name)) {
      typeDefinitions.contents->Array.push(typeDef)
      existingNames->Set.add(name)
    }
  })
  let fullSdl = buildSdl()
  lastFullSdl.contents = Some(fullSdl)
  let resolvers = Dict.make()
  resolvers->Dict.set("Query", queryResolvers.contents)
  resolvers->Dict.set("Mutation", mutationResolvers.contents)
  let schema = YG.createSchema({"typeDefs": fullSdl, "resolvers": resolvers})
  activeSchema.contents = Some(schema)
  let yoga = YG.createYoga({"schema": schema, "graphiql": true, "logging": debug, "maskedErrors": !debug})
  let server = YG.createServer(yoga)
  server->YG.listen(4000, () =>
    log.info(~comp="GraphQL", "rebuilt schema - http://localhost:4000/graphql")
  )
  activeServer.contents = Some(server)
}

// Reset registry state (call between isolated test suites).
let reset = () => {
  mutationResolvers.contents = Dict.make()
  queryResolvers.contents = Dict.make()
  mutationFields.contents = []
  queryFields.contents = []
  typeDefinitions.contents = []
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
    log.info(~comp="GraphQL", "Live SDL:")
    Console.log(sdl)
  | None => log.info(~comp="GraphQL", "no active schema")
  }

type diagnostics = {
  registeredTypeDefinitions: array<string>,
  registeredMutationFields: array<string>,
  registeredQueryFields: array<string>,
  registeredMutationResolvers: array<string>,
  registeredQueryResolvers: array<string>,
  typeCount: int,
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

  let typeNames = typeDefinitions.contents->Array.map(ReventlessCore.GraphQL_Stitcher.extractLeadingName)

  {
    registeredTypeDefinitions: typeNames,
    registeredMutationFields: mutFieldNames,
    registeredQueryFields: queryFieldNames,
    registeredMutationResolvers: mutResolverNames,
    registeredQueryResolvers: queryResolverNames,
    typeCount: typeNames->Array.length,
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
  let p = s => log.info(~comp="GraphQL", s)
  let d = diagnostics()
  p("Diagnostics")
  p(`  Types (${d.typeCount->Int.toString}):`)
  d.registeredTypeDefinitions->Array.forEach(t => p(`    - ${t}`))
  p(
    `  Mutations: ${d.sdlMutationCount->Int.toString} SDL fields, ${d.resolverMutationCount->Int.toString} resolvers`,
  )
  d.registeredMutationFields->Array.forEach(f => p(`    SDL: ${f}`))
  d.registeredMutationResolvers->Array.forEach(r => p(`    Resolver: ${r}`))
  p(
    `  Queries: ${d.sdlQueryCount->Int.toString} SDL fields, ${d.resolverQueryCount->Int.toString} resolvers`,
  )
  d.registeredQueryFields->Array.forEach(f => p(`    SDL: ${f}`))
  d.registeredQueryResolvers->Array.forEach(r => p(`    Resolver: ${r}`))
  if d.mismatches->Array.length > 0 {
    p(`  Mismatches (${d.mismatches->Array.length->Int.toString}):`)
    d.mismatches->Array.forEach(m => p(`    ⚠ ${m}`))
  } else {
    p("  No mismatches")
  }
  p(`  Server running: ${d.serverRunning ? "yes" : "no"}`)
  switch d.fullSdl {
  | Some(sdl) =>
    p("")
    p("--- Full SDL ---")
    sdl->String.split("\n")->Array.forEach(line => p(line))
    p("--- End ---")
  | None => p("  No SDL recorded")
  }
}
