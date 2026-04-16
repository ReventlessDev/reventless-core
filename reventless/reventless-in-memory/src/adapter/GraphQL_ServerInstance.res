// GraphQL server instance factory.
// Creates independent server instances with isolated registries.
// Used by Platform to create separate core and plugin servers in split mode.

module YG = GraphqlYoga

let log = ReventlessCore.Logger.fromEnv()

type resolverFn = YG.resolverFn

@val external processEnv: dict<string> = "process.env"
let debug = processEnv->Dict.get("GRAPHQL_DEBUG")->Option.isSome

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

type t = {
  registerMutations: (~sdlFields: array<string>, ~resolvers: dict<resolverFn>) => unit,
  registerQueries: (~sdlFields: array<string>, ~resolvers: dict<resolverFn>) => unit,
  registerSubscriptions: (~sdlFields: array<string>, ~resolvers: dict<resolverFn>) => unit,
  registerTypes: (~sdlTypes: array<string>) => unit,
  getMutationResolver: string => option<resolverFn>,
  getQueryResolver: string => option<resolverFn>,
  start: (~port: int=?, unit) => unit,
  stop: unit => unit,
  reset: unit => unit,
  buildSdl: unit => string,
  getFullSdl: unit => option<string>,
  getSchema: unit => option<YG.schema>,
  diagnostics: unit => diagnostics,
  printDiagnostics: unit => unit,
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

let make = (~label: string="GraphQL"): t => {
  let mutationResolvers: ref<dict<resolverFn>> = ref(Dict.make())
  let queryResolvers: ref<dict<resolverFn>> = ref(Dict.make())
  let subscriptionResolvers: ref<dict<resolverFn>> = ref(Dict.make())
  let mutationFields: ref<array<string>> = ref([])
  let queryFields: ref<array<string>> = ref([])
  let subscriptionFields: ref<array<string>> = ref([])
  let typeDefinitions: ref<array<string>> = ref([])
  let activeServer: ref<option<YG.httpServer>> = ref(None)
  let activeSchema: ref<option<YG.schema>> = ref(None)
  let lastFullSdl: ref<option<string>> = ref(None)

  let registerMutations = (~sdlFields: array<string>, ~resolvers: dict<resolverFn>) => {
    mutationFields.contents = mutationFields.contents->Array.concat(sdlFields)
    resolvers->Dict.toArray->Array.forEach(((k, v)) => mutationResolvers.contents->Dict.set(k, v))
  }

  let registerQueries = (~sdlFields: array<string>, ~resolvers: dict<resolverFn>) => {
    queryFields.contents = queryFields.contents->Array.concat(sdlFields)
    resolvers->Dict.toArray->Array.forEach(((k, v)) => queryResolvers.contents->Dict.set(k, v))
  }

  let registerSubscriptions = (~sdlFields: array<string>, ~resolvers: dict<resolverFn>) => {
    subscriptionFields.contents = subscriptionFields.contents->Array.concat(sdlFields)
    resolvers->Dict.toArray->Array.forEach(((k, v)) =>
      subscriptionResolvers.contents->Dict.set(k, v)
    )
  }

  let registerTypes = (~sdlTypes: array<string>) => {
    typeDefinitions.contents = typeDefinitions.contents->Array.concat(sdlTypes)
  }

  let getMutationResolver = (fieldName: string): option<resolverFn> =>
    mutationResolvers.contents->Dict.get(fieldName)

  let getQueryResolver = (fieldName: string): option<resolverFn> =>
    queryResolvers.contents->Dict.get(fieldName)

  let buildSdl = () => {
    let typesSdl =
      typeDefinitions.contents->Array.length > 0
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
    let subscriptionsSdl =
      subscriptionFields.contents->Array.length > 0
        ? `\n\ntype Subscription {\n${subscriptionFields.contents->Array.join("\n")}\n}`
        : ""
    let base =
      typesSdl->String.length > 0
        ? typesSdl ++ "\n\n" ++ queriesMutationsSdl
        : queriesMutationsSdl
    base ++ subscriptionsSdl
  }

  let stop = () =>
    switch activeServer.contents {
    | Some(server) =>
      server->YG.close(() => ())
      activeServer.contents = None
      activeSchema.contents = None
    | None => ()
    }

  let start = (~port: int=4000, ()) => {
    let resolvers = Dict.make()
    resolvers->Dict.set("Query", queryResolvers.contents)
    resolvers->Dict.set("Mutation", mutationResolvers.contents)
    if subscriptionResolvers.contents->Dict.keysToArray->Array.length > 0 {
      resolvers->Dict.set("Subscription", subscriptionResolvers.contents)
    }
    let sdl = buildSdl()
    lastFullSdl.contents = Some(sdl)
    let schema = YG.createSchema({"typeDefs": sdl, "resolvers": resolvers})
    activeSchema.contents = Some(schema)
    let yoga = YG.createYoga({
      "schema": schema,
      "graphiql": true,
      "logging": debug,
      "maskedErrors": !debug,
    })
    let server = YG.createServer(yoga)
    server->YG.listen(port, () =>
      log.info(~comp=label, `listening on http://localhost:${port->Int.toString}/graphql`)
    )
    activeServer.contents = Some(server)
  }

  let reset = () => {
    mutationResolvers.contents = Dict.make()
    queryResolvers.contents = Dict.make()
    subscriptionResolvers.contents = Dict.make()
    mutationFields.contents = []
    queryFields.contents = []
    subscriptionFields.contents = []
    typeDefinitions.contents = []
    activeSchema.contents = None
    lastFullSdl.contents = None
  }

  let getFullSdl = () => lastFullSdl.contents
  let getSchema = () => activeSchema.contents

  let diagnostics = (): diagnostics => {
    let mutFieldNames =
      mutationFields.contents->Array.map(extractFieldName)->Array.filter(n => n != "_noop")
    let queryFieldNames =
      queryFields.contents->Array.map(extractFieldName)->Array.filter(n => n != "_noop")
    let mutResolverNames = mutationResolvers.contents->Dict.keysToArray
    let queryResolverNames = queryResolvers.contents->Dict.keysToArray

    let mismatches: array<string> = []

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
    let typeNames =
      typeDefinitions.contents->Array.map(ReventlessCore.GraphQL_Stitcher.extractLeadingName)

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
    let p = s => log.info(~comp=label, s)
    let d = diagnostics()
    p("Diagnostics")
    p(`  Types: ${d.typeCount->Int.toString}`)
    p(
      `  Mutations: ${d.sdlMutationCount->Int.toString} SDL fields, ${d.resolverMutationCount->Int.toString} resolvers`,
    )
    p(
      `  Queries: ${d.sdlQueryCount->Int.toString} SDL fields, ${d.resolverQueryCount->Int.toString} resolvers`,
    )
    if d.mismatches->Array.length > 0 {
      p(`  Mismatches (${d.mismatches->Array.length->Int.toString}):`)
      d.mismatches->Array.forEach(m => p(`    - ${m}`))
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

  {
    registerMutations,
    registerQueries,
    registerSubscriptions,
    registerTypes,
    getMutationResolver,
    getQueryResolver,
    start,
    stop,
    reset,
    buildSdl,
    getFullSdl,
    getSchema,
    diagnostics,
    printDiagnostics,
  }
}
