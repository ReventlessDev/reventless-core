// Domain (plugin-facing) in-memory GraphQL server — singleton.
// Collects SDL fragments and resolver functions from CommandGeneratorResolvers_GraphQL
// (mutations), QueryDbResolvers_GraphQL (queries), and InboundTranslationResolvers_GraphQL
// during Platform.Make().
// start() is called once after all components are built.
//
// Contains domain-specific extras not present in the platform server:
//   - Relay Global ID encoding/decoding (encodeGlobalId / decodeGlobalId)
//   - Node type registry (registerNodeType / registerNodeResolverCallback)
//   - /sdl HTTP endpoint for Relay compiler
//   - rebuildSchema for schema stitching
//
// Note: the old setRegistrationTarget redirect hack has been removed. Routing
// to the platform server is now done explicitly via resolveTargetGraphQL() in
// Platform.res (mirroring the AWS resolveTargetApi() pattern).

module YG = GraphqlYoga

let log = ReventlessCore.Logger.fromEnv()

// -- Node.js HTTP bindings for /sdl endpoint ---------------------------------

type nodeRequest = {url: string}
type nodeResponse
@send external writeHead: (nodeResponse, int, {..}) => unit = "writeHead"
@send external end_: (nodeResponse, string) => unit = "end"

type requestHandler = (nodeRequest, nodeResponse) => unit
@module("http") external createServerWithHandler: requestHandler => YG.httpServer = "createServer"

// -- Auth context factory ----------------------------------------------------
//
// Yoga's initial context wraps the Fetch API Request. We flatten its Headers
// into a lowercase dict, hand it to Auth_InMemory.authenticate, and attach
// the resolved identity to the context so resolvers see `ctx.identity`.

type fetchHeaders
type fetchRequest = {headers: fetchHeaders}
type yogaInitialCtx = {request: fetchRequest}

@send
external headersForEach: (fetchHeaders, (string, string) => unit) => unit = "forEach"

let extractHeaders = (headers: fetchHeaders): dict<string> => {
  let acc = Dict.make()
  headers->headersForEach((value, key) => acc->Dict.set(key->String.toLowerCase, value))
  acc
}

let identityFromAuthResult = (result: Reventless.Identity.authResult): Reventless.Identity.t =>
  switch result {
  | Authenticated(id) => id
  | Anonymous => Reventless.Identity.anonymous
  | AuthError(_) => Reventless.Identity.anonymous
  }

let buildAuthContext = async (initial: YG.initialContext): JSON.t => {
  let ctx: yogaInitialCtx = Obj.magic(initial)
  let headers = extractHeaders(ctx.request.headers)
  let requestContext: ReventlessCore.Auth_Adapter.requestContext = {headers: headers}
  let result = await Auth_InMemory.authenticate(requestContext)
  let identity = identityFromAuthResult(result)
  Obj.magic({"identity": identity})
}

// -- Resolver type alias ---------------------------------------------------

type resolverFn = YG.resolverFn

// -- Relay Global ID encoding/decoding -------------------------------------

@val external btoa: string => string = "btoa"
@val external atob: string => string = "atob"

let encodeGlobalId = (~typeName: string, ~localId: string): string =>
  btoa(`${typeName}:${localId}`)

let decodeGlobalId = (globalId: string): option<(string, string)> =>
  try {
    let decoded = atob(globalId)
    let idx = decoded->String.indexOf(":")
    if idx > 0 {
      let typeName = decoded->String.slice(~start=0, ~end=idx)
      let localId = decoded->String.slice(~start=idx + 1, ~end=decoded->String.length)
      Some((typeName, localId))
    } else {
      None
    }
  } catch {
  | _ => None
  }

// -- Registry --------------------------------------------------------------

let mutationResolvers: ref<dict<resolverFn>> = ref(Dict.make())
let queryResolvers: ref<dict<resolverFn>> = ref(Dict.make())
let subscriptionResolvers: ref<dict<resolverFn>> = ref(Dict.make())

let mutationFields: ref<array<string>> = ref([])
let queryFields: ref<array<string>> = ref([])
let subscriptionFields: ref<array<string>> = ref([])
let typeDefinitions: ref<array<string>> = ref([])

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

/** Look up a registered mutation resolver by field name (used by MCP_Server). */
let getMutationResolver = (fieldName: string): option<resolverFn> =>
  mutationResolvers.contents->Dict.get(fieldName)

/** Look up a registered query resolver by field name (used by MCP_Server). */
let getQueryResolver = (fieldName: string): option<resolverFn> =>
  queryResolvers.contents->Dict.get(fieldName)

let registerTypes = (~sdlTypes: array<string>) =>
  typeDefinitions.contents = typeDefinitions.contents->Array.concat(sdlTypes)

// -- Relay Node type registry -----------------------------------------------
// Maps GraphQL type names to QueryDb component names for node(id: ID!) resolution.
let nodeTypeRegistry: ref<dict<string>> = ref(Dict.make())

let registerNodeType = (~typeName: string, ~queryDbName: string) =>
  nodeTypeRegistry.contents->Dict.set(typeName, queryDbName)

// -- Relay Node resolver callback ------------------------------------------
// Set by QueryDbResolvers_GraphQL to resolve node(id: ID!) queries.
// Takes (typeName, localId) and returns the entity JSON with __typename.
type nodeResolverCallback = (~typeName: string, ~localId: string) => promise<option<JSON.t>>
let nodeResolverCallback: ref<option<nodeResolverCallback>> = ref(None)
let registerNodeResolverCallback = (cb: nodeResolverCallback) =>
  nodeResolverCallback.contents = Some(cb)

// Builds the internal node resolver using the registered callback and type registry.
let buildNodeResolver = (): option<(string, resolverFn)> =>
  switch nodeResolverCallback.contents {
  | None => None
  | Some(resolve) =>
    let resolver: resolverFn = async (_root, args, _ctx) => {
      let id =
        args
        ->JSON.Decode.object
        ->Option.flatMap(d => d->Dict.get("id"))
        ->Option.flatMap(JSON.Decode.string)
        ->Option.getOr("")
      switch decodeGlobalId(id) {
      | Some((typeName, localId)) =>
        switch await resolve(~typeName, ~localId) {
        | Some(entity) => entity
        | None => JSON.Encode.null
        }
      | None => JSON.Encode.null
      }
    }
    Some(("node", resolver))
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

let start = (~port: int=4000, ()) => {
  // Register node resolver if callback is set
  switch buildNodeResolver() {
  | Some((name, resolver)) => queryResolvers.contents->Dict.set(name, resolver)
  | None => ()
  }
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
  let yoga = YG.createYogaWithContext({
    "schema": schema,
    "graphiql": true,
    "logging": debug,
    "maskedErrors": !debug,
    "context": buildAuthContext,
  })
  // Custom HTTP handler: serves /sdl endpoint for Relay compiler, delegates rest to yoga
  let server = createServerWithHandler((req, res) => {
    if req.url == "/sdl" {
      let sdlContent = switch activeSchema.contents {
      | Some(s) => YG.printSchema(s)
      | None => lastFullSdl.contents->Option.getOr("")
      }
      res->writeHead(200, {"Content-Type": "text/plain", "Access-Control-Allow-Origin": "*"})
      res->end_(sdlContent)
    } else {
      (yoga->Obj.magic)(req, res)
    }
  })
  server->YG.listen(port, () =>
    log.info(~comp="GraphQL:Domain", `listening on http://localhost:${port->Int.toString}/graphql (SDL: /sdl)`)
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
  // Register node resolver if callback is set
  switch buildNodeResolver() {
  | Some((name, resolver)) => queryResolvers.contents->Dict.set(name, resolver)
  | None => ()
  }
  let fullSdl = buildSdl()
  lastFullSdl.contents = Some(fullSdl)
  let resolvers = Dict.make()
  resolvers->Dict.set("Query", queryResolvers.contents)
  resolvers->Dict.set("Mutation", mutationResolvers.contents)
  if subscriptionResolvers.contents->Dict.keysToArray->Array.length > 0 {
    resolvers->Dict.set("Subscription", subscriptionResolvers.contents)
  }
  let schema = YG.createSchema({"typeDefs": fullSdl, "resolvers": resolvers})
  activeSchema.contents = Some(schema)
  let yoga = YG.createYogaWithContext({
    "schema": schema,
    "graphiql": true,
    "logging": debug,
    "maskedErrors": !debug,
    "context": buildAuthContext,
  })
  let server = createServerWithHandler((req, res) => {
    if req.url == "/sdl" {
      let sdlContent = switch activeSchema.contents {
      | Some(s) => YG.printSchema(s)
      | None => lastFullSdl.contents->Option.getOr("")
      }
      res->writeHead(200, {"Content-Type": "text/plain", "Access-Control-Allow-Origin": "*"})
      res->end_(sdlContent)
    } else {
      (yoga->Obj.magic)(req, res)
    }
  })
  server->YG.listen(4000, () =>
    log.info(~comp="GraphQL:Domain", "rebuilt schema - http://localhost:4000/graphql (SDL: /sdl)")
  )
  activeServer.contents = Some(server)
}

// Reset registry state (call between isolated test suites).
let reset = () => {
  mutationResolvers.contents = Dict.make()
  queryResolvers.contents = Dict.make()
  subscriptionResolvers.contents = Dict.make()
  mutationFields.contents = []
  queryFields.contents = []
  subscriptionFields.contents = []
  typeDefinitions.contents = []
  nodeTypeRegistry.contents = Dict.make()
  nodeResolverCallback.contents = None
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
    log.info(~comp="GraphQL:Domain", "Live SDL:")
    Console.log(sdl)
  | None => log.info(~comp="GraphQL:Domain", "no active schema")
  }

type diagnostics = GraphQL_ServerInstance.diagnostics

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
  let p = s => log.info(~comp="GraphQL:Domain", s)
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

// -- GraphQL_ServerInstance.t interface ----------------------------------
// Exposes this singleton as a GraphQL_ServerInstance.t for use by
// resolveTargetGraphQL() in Platform.res (mirrors AWS resolveTargetApi() pattern).
let asInterface: GraphQL_ServerInstance.t = {
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
