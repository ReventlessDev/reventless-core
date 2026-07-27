// GraphQL server instance factory.
// Creates independent server instances with isolated registries.
// A backend uses this to stand up one or more Yoga-backed servers from
// stitched SDL fragments + a resolver map, with an optional graphql-ws
// WebSocket endpoint for subscriptions.

module YG = GraphqlYoga

let log = ReventlessCore.Logger.fromEnv()

type resolverFn = YG.resolverFn

// graphql-ws WebSocket transport for subscriptions. Yoga's built-in
// subscription transport is SSE-over-POST; clients using the graphql-ws
// protocol (e.g. host-shell, AppSync clients in prod) need an explicit
// WebSocket endpoint. We attach a `WebSocketServer` to the same HTTP server
// and hand it to `graphql-ws/lib/use/ws::useServer` along with the live
// schema, which fans out subscription events to connected sockets. The `ws`
// and `graphql-ws` externals live in the `GraphqlYoga` bindings.

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
  // `~contextFactory` is the yoga context factory — when supplied, requests
  // run through it so resolvers see `ctx.identity`. Omit (or pass None) for
  // unauthenticated servers. A backend wires its own auth/context factory
  // here so the server enforces the same identity rules across every field
  // instead of leaving queries / mutations wide open.
  start: (~port: int=?, ~contextFactory: YG.contextFactory=?, unit) => unit,
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
    // A mutation field has two legitimate writers: the admin base fragment
    // carries the Plugin aggregate's lifecycle fields, and the aggregate
    // auto-flow registers the same fields when the admin is constructed again
    // for a later deploy onto the same server. buildASTSchema rejects a schema
    // that defines a field twice, so keep the first SDL definition and drop
    // repeats by field name — mirroring the resolver dict, where a repeat
    // registration overwrites by key (last resolver wins).
    let existing = Set.fromArray(mutationFields.contents->Array.map(extractFieldName))
    let fresh = sdlFields->Array.filter(f => !(existing->Set.has(extractFieldName(f))))
    mutationFields.contents = mutationFields.contents->Array.concat(fresh)
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

  // Identical type blocks dedupe: shared-type registrations (e.g. the
  // CommandResult union family) may be repeated by every component that needs
  // them; a duplicate definition in one document would fail createSchema.
  let registerTypes = (~sdlTypes: array<string>) => {
    sdlTypes->Array.forEach(t =>
      if !(typeDefinitions.contents->Array.includes(t)) {
        typeDefinitions.contents->Array.push(t)
      }
    )
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

  let start = (~port: int=4000, ~contextFactory: option<YG.contextFactory>=?, ()) => {
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
    // Route yoga's own logging into the framework logger. error/warn ALWAYS
    // surface (so a masked resolver failure — which yoga reports via logger.error
    // with the original Error even when the client response is masked — is never
    // swallowed), while verbose debug/info stay gated on GRAPHQL_DEBUG.
    let yogaLogging: YG.yogaLogger = {
      debug: a => if debug { log.debug(~comp=label, YG.logArgToString(a)) },
      info: a => if debug { log.info(~comp=label, YG.logArgToString(a)) },
      warn: a => log.warn(~comp=label, YG.logArgToString(a)),
      error: a => log.error(~comp=label, YG.logArgToString(a)),
    }
    let yoga = switch contextFactory {
    | Some(ctx) =>
      YG.createYogaWithContext({
        "schema": schema,
        "graphiql": true,
        "logging": yogaLogging,
        "maskedErrors": !debug,
        "context": ctx,
      })
    | None =>
      YG.createYoga({
        "schema": schema,
        "graphiql": true,
        "logging": yogaLogging,
        "maskedErrors": !debug,
      })
    }
    let server = YG.createServer(yoga)
    server->YG.listen(port, () =>
      log.info(~comp=label, `listening on http://localhost:${port->Int.toString}/graphql`)
    )
    if subscriptionResolvers.contents->Dict.keysToArray->Array.length > 0 {
      let wss = YG.newWebSocketServer({"server": server, "path": "/graphql"})
      YG.wsUseServer({"schema": schema}, wss)
      log.info(~comp=label, `graphql-ws subscriptions on ws://localhost:${port->Int.toString}/graphql`)
    }
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
