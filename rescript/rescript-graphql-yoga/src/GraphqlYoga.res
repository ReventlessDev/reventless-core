// ReScript bindings for graphql-yoga v5 + Node.js http

// ─── Opaque types ──────────────────────────────────────────────────────────

/** A compiled GraphQL schema (typeDefs + resolvers combined). */
type schema

/**
 * A Yoga server instance.
 * Also acts as a Node.js-compatible request handler:
 * pass directly to `http.createServer`.
 */
type yoga

/** A Node.js `http.Server` instance. */
type httpServer

// ─── Resolver types ────────────────────────────────────────────────────────

/**
 * A GraphQL resolver function.
 * Signature: `(root, args) => promise<result>`
 *
 * Both `root` and `args` are typed as `JSON.t` for generic usage.
 * Use `Obj.magic` at the call site to cast to more specific types when needed.
 */
type resolverFn = (JSON.t, JSON.t) => promise<JSON.t>

// ─── Schema creation ───────────────────────────────────────────────────────

/**
 * Creates a GraphQL schema from SDL type definitions and a resolver map.
 *
 * The `resolvers` dict maps GraphQL type names to field resolver dicts:
 * ```rescript
 * let resolvers = Dict.make()
 * let queryResolvers = Dict.make()
 * queryResolvers->Dict.set("item", async (_root, args) => { ... })
 * resolvers->Dict.set("Query", queryResolvers)
 * resolvers->Dict.set("Mutation", mutationResolvers)
 * let schema = createSchema({ "typeDefs": sdl, "resolvers": resolvers })
 * ```
 */
@module("graphql-yoga")
external createSchema: {
  "typeDefs": string,
  "resolvers": dict<dict<resolverFn>>,
} => schema = "createSchema"

// ─── Server creation ───────────────────────────────────────────────────────

/**
 * Creates a Yoga server from a schema.
 *
 * The returned `yoga` value is a Node.js-compatible request handler.
 * Pass it directly to `createServer`:
 * ```rescript
 * let yoga = createYoga({ "schema": schema, "graphiql": true, "logging": false })
 * let server = createServer(yoga)
 * server->listen(4000, () => Console.log("Listening on :4000"))
 * ```
 */
@module("graphql-yoga")
external createYoga: {
  "schema": schema,
  "graphiql": bool,
  "logging": bool,
  "maskedErrors": bool,
} => yoga = "createYoga"

/**
 * Creates a Node.js HTTP server using the Yoga instance as the request handler.
 * Yoga v5 implements the Node.js `RequestListener` interface directly.
 */
@module("http")
external createServer: yoga => httpServer = "createServer"

// ─── Server lifecycle ──────────────────────────────────────────────────────

/** Start listening on the given port. Calls `callback` when ready. */
@send
external listen: (httpServer, int, unit => unit) => unit = "listen"

/** Stop accepting new connections. Calls `callback` when all connections are closed. */
@send
external close: (httpServer, unit => unit) => unit = "close"

// ─── Schema introspection ─────────────────────────────────────────────────

/** Returns the canonical SDL string from a live GraphQL schema object. */
@module("graphql")
external printSchema: schema => string = "printSchema"
