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
//
// Note: the old setRegistrationTarget redirect hack has been removed. Routing
// to the platform server is now done explicitly via resolveTargetGraphQL() in
// Platform.res (mirroring the AWS resolveTargetApi() pattern).

module YG = GraphqlYoga

let log = ReventlessCore.Logger.fromEnv()

// -- Node.js HTTP bindings ---------------------------------------------------
// /sdl serves the printed schema; /__inmemory/login & /logout serve the A4
// token-issuance endpoints. Everything else falls through to graphql-yoga.

type nodeRequest = {url: string, method: string, headers: dict<string>}
type nodeResponse
@send external writeHead: (nodeResponse, int, {..}) => unit = "writeHead"
@send external end_: (nodeResponse, string) => unit = "end"
@send external endEmpty: (nodeResponse, @as(json`null`) _) => unit = "end"
// Binary response body — the served-object GET streams stored bytes verbatim.
@send external endBuf: (nodeResponse, LocalObjectStore.buffer) => unit = "end"

// Streaming body collector — request data fires once per chunk, end once at EOF.
@send external _onData: (nodeRequest, @as("data") _, string => unit) => unit = "on"
@send external _onEnd: (nodeRequest, @as("end") _, unit => unit) => unit = "on"
@send external _setEncoding: (nodeRequest, string) => unit = "setEncoding"
// Binary chunk stream — used by the served-object PUT so raw bytes aren't
// mangled by utf8 decoding (setEncoding is deliberately NOT called).
@send external _onDataBuf: (nodeRequest, @as("data") _, LocalObjectStore.buffer => unit) => unit = "on"


let readBody = (req: nodeRequest, onBody: string => unit): unit => {
  let buf = ref("")
  req->_setEncoding("utf8")
  req->_onData(chunk => buf := buf.contents ++ chunk)
  req->_onEnd(() => onBody(buf.contents))
}

// Binary body collector — accumulates raw Buffer chunks and concatenates once
// at EOF. Kept separate from `readBody` (utf8) so file uploads stay byte-exact.
let readBodyBuf = (req: nodeRequest, onBody: LocalObjectStore.buffer => unit): unit => {
  let chunks: array<LocalObjectStore.buffer> = []
  req->_onDataBuf(chunk => chunks->Array.push(chunk))
  req->_onEnd(() => onBody(LocalObjectStore.concatBuffers(chunks)))
}

type requestHandler = (nodeRequest, nodeResponse) => unit
@module("http") external createServerWithHandler: requestHandler => YG.httpServer = "createServer"

// http.Server emits `error` (e.g. EADDRINUSE) instead of throwing from listen().
// Without a handler the failure is silent — listen()'s success callback never
// fires, the server never binds, and requests fall through to whatever else
// holds the port. We attach one so a bind failure surfaces loudly.
@send external _onServerError: (YG.httpServer, @as("error") _, JsExn.t => unit) => unit = "on"

// -- /__inmemory/login + /logout handlers -----------------------------------

let _writeJson = (res: nodeResponse, ~status: int, body: JSON.t): unit => {
  res->writeHead(
    status,
    {"Content-Type": "application/json", "Access-Control-Allow-Origin": "*"},
  )
  res->end_(body->JSON.stringify)
}

let _loginRejected = (res: nodeResponse, ~error: string): unit =>
  _writeJson(
    res,
    ~status=401,
    JSON.Encode.object(Dict.fromArray([("error", JSON.Encode.string(error))])),
  )

type _loginBody = {username: string, password: string}

let handleLogin = (req: nodeRequest, res: nodeResponse): unit =>
  readBody(req, body => {
    let parsed = try {
      Some((body->JSON.parseOrThrow->Obj.magic: _loginBody))
    } catch {
    | _ => None
    }
    switch parsed {
    | None => _loginRejected(res, ~error="Invalid JSON body")
    | Some({username, password}) =>
      let _ = LocalAuth.Login.issue(~username, ~password)->Promise.then(result => {
        switch result {
        | Error(msg) => _loginRejected(res, ~error=msg)
        | Ok(token) =>
          // Echo back the identity the client will see in subsequent
          // ctx.identity values, so the SPA doesn't need a second round-trip.
          let identity = switch LocalAuth.lookupUser(username) {
          | Some(i) => i
          | None => Reventless.Identity.anonymous
          }
          let identityJson =
            identity->S.reverseConvertToJsonOrThrow(Reventless.Identity.schema)
          _writeJson(
            res,
            ~status=200,
            JSON.Encode.object(
              Dict.fromArray([
                ("token", JSON.Encode.string(token)),
                ("identity", identityJson),
              ]),
            ),
          )
        }
        Promise.resolve()
      })
    }
  })

let handleLogout = (_req: nodeRequest, res: nodeResponse): unit => {
  res->writeHead(204, {"Access-Control-Allow-Origin": "*"})
  res->endEmpty
}

// -- Served-bucket routes (local analogue of the AWS CloudFront read path) ----
//
// The dev platform has no object bucket, so these three routes back the same
// UI contract locally against `LocalObjectStore`:
//   POST /__inmemory/upload  {fileName,contentType} → {uploadUrl, storageRef}
//   PUT  /{prefix}/{key}     raw bytes              → 200 (store)
//   GET  /{prefix}/{key}                            → the stored bytes
// `uploadUrl == storageRef == /{prefix}/{key}`, so the existing FileDropzone S3
// adapter (POST-presign → PUT-bytes) works unchanged — no presigning needed.

let uploadPresignPath = "/__inmemory/upload"

// CORS for the browser PUT (a cross-origin preflight when the dev origin isn't
// same-origin with the API); the seed uploads from Node and needs none.
let _corsWriteHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "PUT,GET,OPTIONS",
  "Access-Control-Allow-Headers": "*",
}

// Presign-shaped: mint a fresh uuid key under the served prefix and hand back a
// same-origin `/{prefix}/{key}` for both the PUT target and the stored ref.
let handleUploadPresign = (req: nodeRequest, res: nodeResponse): unit =>
  readBody(req, body => {
    let parsed =
      try body->JSON.parseOrThrow->JSON.Decode.object->Option.getOr(Dict.make()) catch {
      | _ => Dict.make()
      }
    let fileName =
      parsed->Dict.get("fileName")->Option.flatMap(JSON.Decode.string)->Option.getOr("upload")
    let ref = `/${LocalObjectStore.defaultUploadPrefix}/${NodeCrypto.randomUUID()}/${fileName}`
    _writeJson(
      res,
      ~status=200,
      JSON.Encode.object(
        Dict.fromArray([
          ("uploadUrl", JSON.Encode.string(ref)),
          ("storageRef", JSON.Encode.string(ref)),
        ]),
      ),
    )
  })

let handleObjectPut = (req: nodeRequest, res: nodeResponse, ~key: string): unit => {
  let contentType =
    req.headers->Dict.get("content-type")->Option.getOr("application/octet-stream")
  readBodyBuf(req, bytes => {
    LocalObjectStore.put(~key, ~bytes, ~contentType)
    res->writeHead(200, _corsWriteHeaders)
    res->end_("")
  })
}

let handleObjectGet = (res: nodeResponse, ~key: string): unit =>
  switch LocalObjectStore.get(~key) {
  | Some({bytes, contentType}) =>
    res->writeHead(
      200,
      {
        "Content-Type": contentType,
        "Access-Control-Allow-Origin": "*",
        "Cache-Control": "public, max-age=31536000, immutable",
      },
    )
    res->endBuf(bytes)
  | None =>
    res->writeHead(404, {"Access-Control-Allow-Origin": "*"})
    res->endEmpty
  }

// Returns true when the request carries an `Authorization: Bearer <token>`
// header whose token fails HMAC verification. No header (anonymous), or a
// non-Bearer scheme (e.g. X-User flows), returns false — only an *invalid*
// Bearer is a rejection. Mirrors the LocalAuth.authenticate decoding
// rule so HTTP-level rejection matches resolver-level identity.
let _isInvalidBearer = (req: nodeRequest): bool =>
  switch req.headers->Dict.get("authorization") {
  | Some(h) if String.startsWith(h, "Bearer ") =>
    let token =
      String.slice(h, ~start=7, ~end=String.length(h))->String.trim
    LocalAuth.Login.verifyAndDecode(token)->Option.isNone
  | _ => false
  }

// Shared dispatch for start(). Order matters: built-in
// endpoints win over the yoga catch-all so they aren't shadowed by graphql.
let _dispatch = (req: nodeRequest, res: nodeResponse, yoga: YG.yoga, getSdl: unit => string): unit => {
  // Strip query string before path matching.
  let path = req.url->String.split("?")->Array.get(0)->Option.getOr(req.url)
  // /__inmemory/login is the path that *issues* tokens — it never carries
  // one. Every other path must reject an unverifiable Bearer with 401 so
  // the host-shell's `on401` logout path can fire on stale tokens.
  if path != "/__inmemory/login" && _isInvalidBearer(req) {
    _writeJson(
      res,
      ~status=401,
      JSON.Encode.object(
        Dict.fromArray([("error", JSON.Encode.string("Invalid bearer token"))]),
      ),
    )
  } else if path == "/sdl" {
    res->writeHead(200, {"Content-Type": "text/plain", "Access-Control-Allow-Origin": "*"})
    res->end_(getSdl())
  } else if path == "/__inmemory/login" && req.method == "POST" {
    handleLogin(req, res)
  } else if path == "/__inmemory/logout" && req.method == "POST" {
    handleLogout(req, res)
  } else if path == uploadPresignPath && req.method == "POST" {
    handleUploadPresign(req, res)
  } else if path == "/events" && req.method == "POST" {
    // Local AppSync Events publish endpoint (`/client/**` only). The
    // Authorization header carries the token raw (AWS Cognito-publish shape),
    // so it bypasses `_isInvalidBearer` above and is verified inside.
    let authorization = req.headers->Dict.get("authorization")
    readBody(req, body => {
      let (status, json) = LocalEvents_Server.handlePublish(~authorization, ~body)
      _writeJson(res, ~status, json)
    })
  } else if path == "/events" && req.method == "OPTIONS" {
    // Preflight for the cross-origin browser publish (Authorization header).
    res->writeHead(
      204,
      {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "POST,OPTIONS",
        "Access-Control-Allow-Headers": "*",
      },
    )
    res->endEmpty
  } else if req.method == "OPTIONS" && LocalObjectStore.servedKey(path)->Option.isSome {
    // Preflight for the cross-origin browser PUT to a served-object path.
    res->writeHead(204, _corsWriteHeaders)
    res->endEmpty
  } else if req.method == "PUT" && LocalObjectStore.servedKey(path)->Option.isSome {
    handleObjectPut(req, res, ~key=LocalObjectStore.servedKey(path)->Option.getOr(""))
  } else if req.method == "GET" && LocalObjectStore.servedKey(path)->Option.isSome {
    handleObjectGet(res, ~key=LocalObjectStore.servedKey(path)->Option.getOr(""))
  } else {
    (yoga->Obj.magic)(req, res)
  }
}

// -- Auth context factory ----------------------------------------------------
//
// Yoga's initial context wraps the Fetch API Request. The shared
// `Auth_GraphqlContext.buildAuthContext` flattens headers into a lowercase
// dict, runs them through `LocalAuth.authenticate`, and attaches the
// resolved identity to the resolver context. Lifted into its own module so
// the split-mode admin server (`ReventlessGraphqlServer.GraphQL_ServerInstance`) enforces the same
// bearer-token rules instead of leaving admin queries wide open.

let buildAuthContext = Auth_GraphqlContext.buildAuthContext

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

// -- Scoped registry ---------------------------------------------------------
// Mirrors the AWS plugin=source-API, platform=merged-API model: every
// registration lands in the bucket of the *current scope*. The default
// "platform" scope holds admin/base registrations; Platform.res wraps each
// plugin's construction in its own scope (setScope/relabelScope/resetScope)
// so a plugin's SDL fragment + resolvers form a standalone subgraph that is
// validated in isolation and composed at start().

let platformScope = "platform"

type bucket = {
  mutable mutationFields: array<string>,
  mutable queryFields: array<string>,
  mutable subscriptionFields: array<string>,
  mutable typeDefinitions: array<string>,
  mutationResolvers: dict<resolverFn>,
  queryResolvers: dict<resolverFn>,
  subscriptionResolvers: dict<resolverFn>,
}

let makeBucket = (~scope: string): bucket => {
  mutationFields: [],
  queryFields: [],
  subscriptionFields: [],
  // Non-platform (plugin) buckets are seeded with the Relay base types so
  // their standalone documents are self-contained — mirrors the AWS path
  // where stitchStandalone embeds the shared types in every subgraph SDL.
  // Identical copies dedupe in the final merge.
  typeDefinitions: scope == platformScope
    ? []
    : ReventlessCore.GraphQL_Stitcher.relayBaseTypes->Array.copy,
  mutationResolvers: Dict.make(),
  queryResolvers: Dict.make(),
  subscriptionResolvers: Dict.make(),
}

// Insertion order = composition order (platform bucket is forced first in
// orderedBuckets regardless of creation order).
let buckets: ref<dict<bucket>> = ref(Dict.make())
let currentScope: ref<string> = ref(platformScope)

let bucketFor = (scope: string): bucket =>
  switch buckets.contents->Dict.get(scope) {
  | Some(b) => b
  | None =>
    let b = makeBucket(~scope)
    buckets.contents->Dict.set(scope, b)
    b
  }

let currentBucket = () => bucketFor(currentScope.contents)

/** Route subsequent registrations into the named scope's bucket. */
let setScope = (name: string) => {
  currentScope.contents = name
  let _ = bucketFor(name)
}

/** Route subsequent registrations back into the default "platform" bucket. */
let resetScope = () => currentScope.contents = platformScope

/** Rename a scope bucket. Platform.res scopes a plugin's construction with a
    token (the plugin name is only known after construction) and relabels the
    bucket to the plugin name afterwards. Merges into `to_` if it exists. */
let relabelScope = (~from: string, ~to_: string) =>
  if from != to_ {
    switch buckets.contents->Dict.get(from) {
    | None => ()
    | Some(b) =>
      buckets.contents->Dict.delete(from)
      switch buckets.contents->Dict.get(to_) {
      | None => buckets.contents->Dict.set(to_, b)
      | Some(existing) =>
        existing.mutationFields = existing.mutationFields->Array.concat(b.mutationFields)
        existing.queryFields = existing.queryFields->Array.concat(b.queryFields)
        existing.subscriptionFields =
          existing.subscriptionFields->Array.concat(b.subscriptionFields)
        b.typeDefinitions->Array.forEach(t =>
          if !(existing.typeDefinitions->Array.includes(t)) {
            existing.typeDefinitions->Array.push(t)
          }
        )
        b.mutationResolvers
        ->Dict.toArray
        ->Array.forEach(((k, v)) => existing.mutationResolvers->Dict.set(k, v))
        b.queryResolvers
        ->Dict.toArray
        ->Array.forEach(((k, v)) => existing.queryResolvers->Dict.set(k, v))
        b.subscriptionResolvers
        ->Dict.toArray
        ->Array.forEach(((k, v)) => existing.subscriptionResolvers->Dict.set(k, v))
      }
      if currentScope.contents == from {
        currentScope.contents = to_
      }
    }
  }

// Platform bucket first, then the plugin buckets in creation order.
let orderedBuckets = (): array<(string, bucket)> => {
  let entries = buckets.contents->Dict.toArray
  entries
  ->Array.filter(((scope, _)) => scope == platformScope)
  ->Array.concat(entries->Array.filter(((scope, _)) => scope != platformScope))
}

let registerMutations = (~sdlFields: array<string>, ~resolvers: dict<resolverFn>) => {
  let b = currentBucket()
  b.mutationFields = b.mutationFields->Array.concat(sdlFields)
  resolvers->Dict.toArray->Array.forEach(((k, v)) => b.mutationResolvers->Dict.set(k, v))
}

let registerQueries = (~sdlFields: array<string>, ~resolvers: dict<resolverFn>) => {
  let b = currentBucket()
  b.queryFields = b.queryFields->Array.concat(sdlFields)
  resolvers->Dict.toArray->Array.forEach(((k, v)) => b.queryResolvers->Dict.set(k, v))
}

let registerSubscriptions = (~sdlFields: array<string>, ~resolvers: dict<resolverFn>) => {
  let b = currentBucket()
  b.subscriptionFields = b.subscriptionFields->Array.concat(sdlFields)
  resolvers->Dict.toArray->Array.forEach(((k, v)) => b.subscriptionResolvers->Dict.set(k, v))
}

/** Look up a registered mutation resolver by field name (used by MCP_Server).
    Searches all scope buckets. */
let getMutationResolver = (fieldName: string): option<resolverFn> =>
  buckets.contents
  ->Dict.valuesToArray
  ->Array.findMap(b => b.mutationResolvers->Dict.get(fieldName))

/** Look up a registered query resolver by field name (used by MCP_Server).
    Searches all scope buckets. */
let getQueryResolver = (fieldName: string): option<resolverFn> =>
  buckets.contents
  ->Dict.valuesToArray
  ->Array.findMap(b => b.queryResolvers->Dict.get(fieldName))

// Identical type blocks dedupe within a bucket, so shared-type registrations
// (CommandResult union family, Relay base types) can be repeated per scope —
// each plugin bucket carries its own copy and stays standalone-valid.
let registerTypes = (~sdlTypes: array<string>) => {
  let b = currentBucket()
  sdlTypes->Array.forEach(t =>
    if !(b.typeDefinitions->Array.includes(t)) {
      b.typeDefinitions->Array.push(t)
    }
  )
}

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

let debug = NodeProcess.env->Dict.get("GRAPHQL_DEBUG")->Option.isSome

let activeServer: ref<option<YG.httpServer>> = ref(None)
let activeSchema: ref<option<YG.schema>> = ref(None)
let lastFullSdl: ref<option<string>> = ref(None)

// Shared SDL assembly for one bucket. `withRootDefaults` keeps the historical
// behavior of always emitting Query/Mutation (with a `_noop` placeholder when
// empty) — required for the platform bucket so the composed schema always has
// a Query type. Plugin buckets omit empty root types (their standalone
// documents mirror an AWS source-API schema).
let assembleBucketSdl = (
  ~typeDefinitions: array<string>,
  ~queryFields: array<string>,
  ~mutationFields: array<string>,
  ~subscriptionFields: array<string>,
  ~withRootDefaults: bool,
): string => {
  let sections = []
  if typeDefinitions->Array.length > 0 {
    sections->Array.push(typeDefinitions->Array.join("\n\n"))
  }
  if withRootDefaults || queryFields->Array.length > 0 {
    let queries =
      queryFields->Array.length > 0 ? queryFields->Array.join("\n") : "  _noop: String"
    sections->Array.push(`type Query {\n${queries}\n}`)
  }
  if withRootDefaults || mutationFields->Array.length > 0 {
    let mutations =
      mutationFields->Array.length > 0 ? mutationFields->Array.join("\n") : "  _noop: String"
    sections->Array.push(`type Mutation {\n${mutations}\n}`)
  }
  if subscriptionFields->Array.length > 0 {
    sections->Array.push(`type Subscription {\n${subscriptionFields->Array.join("\n")}\n}`)
  }
  sections->Array.join("\n\n")
}

// Standalone subgraph document for a plugin bucket (empty root types omitted).
let buildScopeSdl = (b: bucket): string =>
  assembleBucketSdl(
    ~typeDefinitions=b.typeDefinitions,
    ~queryFields=b.queryFields,
    ~mutationFields=b.mutationFields,
    ~subscriptionFields=b.subscriptionFields,
    ~withRootDefaults=false,
  )

// Aggregated SDL across all buckets (diagnostics / registered-SDL view).
// Identical type blocks registered in multiple buckets appear once.
let buildSdl = () => {
  let seenTypes = Set.make()
  let allTypes: array<string> = []
  let allQueries: array<string> = []
  let allMutations: array<string> = []
  let allSubscriptions: array<string> = []
  orderedBuckets()->Array.forEach(((_, b)) => {
    b.typeDefinitions->Array.forEach(t =>
      if !(seenTypes->Set.has(t)) {
        seenTypes->Set.add(t)
        allTypes->Array.push(t)
      }
    )
    allQueries->Array.pushMany(b.queryFields)
    allMutations->Array.pushMany(b.mutationFields)
    allSubscriptions->Array.pushMany(b.subscriptionFields)
  })
  assembleBucketSdl(
    ~typeDefinitions=allTypes,
    ~queryFields=allQueries,
    ~mutationFields=allMutations,
    ~subscriptionFields=allSubscriptions,
    ~withRootDefaults=true,
  )
}

// `~contextFactory` is accepted to satisfy the `ReventlessGraphqlServer.GraphQL_ServerInstance.t`
// interface but ignored — the data server always wires `buildAuthContext`
// internally so the bearer-token rules + /__inmemory/login + /sdl dispatch
// stay consistent across callers.
let exnMessage = (exn: exn): string =>
  exn
  ->JsExn.fromException
  ->Option.flatMap(JsExn.message)
  ->Option.getOr("unknown error")

// Per-bucket root resolver map ({Query, Mutation, Subscription} — empty roots
// omitted except for the platform bucket which always carries Query/Mutation,
// matching its `_noop` root defaults).
let scopeResolverMap = (b: bucket, ~withRootDefaults: bool): dict<dict<resolverFn>> => {
  let resolvers = Dict.make()
  if withRootDefaults || b.queryResolvers->Dict.keysToArray->Array.length > 0 {
    resolvers->Dict.set("Query", b.queryResolvers)
  }
  if withRootDefaults || b.mutationResolvers->Dict.keysToArray->Array.length > 0 {
    resolvers->Dict.set("Mutation", b.mutationResolvers)
  }
  if b.subscriptionResolvers->Dict.keysToArray->Array.length > 0 {
    resolvers->Dict.set("Subscription", b.subscriptionResolvers)
  }
  resolvers
}

let scopeHasFields = (b: bucket): bool =>
  b.mutationFields->Array.length > 0 ||
  b.queryFields->Array.length > 0 ||
  b.subscriptionFields->Array.length > 0

/** Validate every plugin bucket's standalone document, then compose the final
    schema from one document + one resolver map per bucket (platform first) via
    graphql-tools merge semantics — mirrors AWS source-API validation followed
    by the merged-API build. Exposed for start() and tests. */
let composeSchema = (): YG.schema => {
  // Standalone validation per plugin bucket — a plugin whose document
  // references types it does not define itself fails HERE, with attribution,
  // before the cross-plugin merge (mirrors AWS: each source API schema must
  // be valid standalone).
  orderedBuckets()->Array.forEach(((scope, b)) =>
    if scope != platformScope && scopeHasFields(b) {
      let doc = buildScopeSdl(b)
      try {
        let _ = YG.createSchema({
          "typeDefs": doc,
          "resolvers": scopeResolverMap(b, ~withRootDefaults=false),
        })
      } catch {
      | e =>
        JsError.throwWithMessage(
          `Plugin "${scope}" subgraph document is not valid standalone: ${exnMessage(e)}`,
        )
      }
    }
  )

  // Composition — graphql-tools mergeTypeDefs/mergeResolvers semantics:
  // identical duplicate type definitions dedupe; conflicting same-named
  // definitions throw naming the type (the local equivalent of MERGE_FAILED).
  let platformBucket = bucketFor(platformScope)
  let docs = [
    assembleBucketSdl(
      ~typeDefinitions=platformBucket.typeDefinitions,
      ~queryFields=platformBucket.queryFields,
      ~mutationFields=platformBucket.mutationFields,
      ~subscriptionFields=platformBucket.subscriptionFields,
      ~withRootDefaults=true,
    ),
  ]
  let resolverMaps = [scopeResolverMap(platformBucket, ~withRootDefaults=true)]
  orderedBuckets()->Array.forEach(((scope, b)) =>
    if scope != platformScope {
      let doc = buildScopeSdl(b)
      if doc->String.length > 0 {
        docs->Array.push(doc)
        resolverMaps->Array.push(scopeResolverMap(b, ~withRootDefaults=false))
      }
    }
  )
  try {
    YG.createSchemaMulti({"typeDefs": docs, "resolvers": resolverMaps})
  } catch {
  | e =>
    JsError.throwWithMessage(
      `Cross-plugin schema merge failed (mirrors AWS MERGE_FAILED): ${exnMessage(e)}`,
    )
  }
}

let start = (~port: int=4000, ~contextFactory as _: option<YG.contextFactory>=?, ()) => {
  // Register node resolver if callback is set — the node()/Node registry is
  // platform-owned (local keeps its working in-process node()).
  switch buildNodeResolver() {
  | Some((name, resolver)) => bucketFor(platformScope).queryResolvers->Dict.set(name, resolver)
  | None => ()
  }
  lastFullSdl.contents = Some(buildSdl())
  let schema = composeSchema()
  activeSchema.contents = Some(schema)
  // Route yoga's own logging into the framework logger. error/warn ALWAYS surface
  // (so a masked resolver failure — which yoga reports via logger.error with the
  // original Error even when the client response is masked — is never swallowed
  // again), while verbose debug/info stay gated on GRAPHQL_DEBUG.
  let yogaLogging: YG.yogaLogger = {
    debug: a => if debug { log.debug(~comp="GraphQL:Domain", YG.logArgToString(a)) },
    info: a => if debug { log.info(~comp="GraphQL:Domain", YG.logArgToString(a)) },
    warn: a => log.warn(~comp="GraphQL:Domain", YG.logArgToString(a)),
    error: a => log.error(~comp="GraphQL:Domain", YG.logArgToString(a)),
  }
  let yoga = YG.createYogaWithContext({
    "schema": schema,
    "graphiql": true,
    "logging": yogaLogging,
    "maskedErrors": !debug,
    "context": buildAuthContext,
  })
  // Custom HTTP handler: serves /sdl + /__inmemory/{login,logout}, else yoga.
  let getSdl = () =>
    switch activeSchema.contents {
    | Some(s) => YG.printSchema(s)
    | None => lastFullSdl.contents->Option.getOr("")
    }
  let server = createServerWithHandler((req, res) => _dispatch(req, res, yoga, getSdl))
  server->_onServerError(err => {
    let detail = err->JsExn.message->Option.getOr("unknown error")
    log.error(
      ~comp="GraphQL:Domain",
      `failed to bind port ${port->Int.toString}: ${detail} — ` ++
      `is another server (dev server, prior test) already listening there?`,
    )
    // Re-raise so the failure is loud instead of a silently-unbound server whose
    // requests fall through to whatever else holds the port.
    JsError.throwWithMessage(`DomainGraphQL_Server could not bind port ${port->Int.toString}: ${detail}`)
  })
  server->YG.listen(port, () =>
    log.info(~comp="GraphQL:Domain", `listening on http://localhost:${port->Int.toString}/graphql (SDL: /sdl)`)
  )
  // Local AppSync Events transport (subscribe WS). Attached here so every
  // start mode (split, unified, replay) carries it.
  LocalEvents_Server.attach(~server, ~port)
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

// Reset registry state (call between isolated test suites). Clears all scope
// buckets and restores the default "platform" scope.
let reset = () => {
  buckets.contents = Dict.make()
  currentScope.contents = platformScope
  nodeTypeRegistry.contents = Dict.make()
  nodeResolverCallback.contents = None
  activeSchema.contents = None
  lastFullSdl.contents = None
  LocalObjectStore.reset()
}

// -- Inspection & diagnostics ---------------------------------------------

let getRegisteredSdl = () => buildSdl()

type resolverNames = {mutations: array<string>, queries: array<string>}

let getRegisteredResolverNames = (): resolverNames => {
  mutations: orderedBuckets()->Array.flatMap(((_, b)) => b.mutationResolvers->Dict.keysToArray),
  queries: orderedBuckets()->Array.flatMap(((_, b)) => b.queryResolvers->Dict.keysToArray),
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

type diagnostics = ReventlessGraphqlServer.GraphQL_ServerInstance.diagnostics

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
  let allBuckets = orderedBuckets()->Array.map(((_, b)) => b)
  let mutFieldNames =
    allBuckets
    ->Array.flatMap(b => b.mutationFields)
    ->Array.map(extractFieldName)
    ->Array.filter(n => n != "_noop")
  let queryFieldNames =
    allBuckets
    ->Array.flatMap(b => b.queryFields)
    ->Array.map(extractFieldName)
    ->Array.filter(n => n != "_noop")
  let mutResolverNames = allBuckets->Array.flatMap(b => b.mutationResolvers->Dict.keysToArray)
  let queryResolverNames = allBuckets->Array.flatMap(b => b.queryResolvers->Dict.keysToArray)

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

  // Identical type blocks registered in multiple scopes count once (they
  // dedupe in the composed schema).
  let seenTypeBlocks = Set.make()
  let typeNames: array<string> = []
  allBuckets->Array.forEach(b =>
    b.typeDefinitions->Array.forEach(t =>
      if !(seenTypeBlocks->Set.has(t)) {
        seenTypeBlocks->Set.add(t)
        typeNames->Array.push(ReventlessCore.GraphQL_Stitcher.extractLeadingName(t))
      }
    )
  )

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

// -- ReventlessGraphqlServer.GraphQL_ServerInstance.t interface ----------------------------------
// Exposes this singleton as a ReventlessGraphqlServer.GraphQL_ServerInstance.t for use by
// resolveTargetGraphQL() in Platform.res (mirrors AWS resolveTargetApi() pattern).
let asInterface: ReventlessGraphqlServer.GraphQL_ServerInstance.t = {
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
