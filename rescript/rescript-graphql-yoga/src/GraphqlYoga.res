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
 * Signature: `(root, args, context) => promise<result>`
 *
 * `root`, `args`, and `context` are typed as `JSON.t` for generic usage.
 * graphql-yoga populates `context` with `{ request: Request, ... }` by default.
 * Use `Obj.magic` at the call site to cast to more specific types when needed.
 */
type resolverFn = (JSON.t, JSON.t, JSON.t) => promise<JSON.t>

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
/**
 * Initial context passed to a context-factory function. Yoga populates it
 * with the incoming Fetch API `Request` (plus `params`, `serverContext`,
 * etc.); the factory's return value is merged into what resolvers see as
 * their `context` argument.
 *
 * Typed as `JSON.t` so callers `Obj.magic` to the concrete shape they need
 * — typically a record with a `request` field exposing `headers`.
 */
type initialContext = JSON.t

/**
 * Context factory: receives Yoga's initial context (with `request: Request`)
 * and returns the additional fields merged into resolver `context`.
 *
 * Pattern:
 * ```rescript
 * let buildContext: initialContext => promise<JSON.t> = async initial => {
 *   let req: {"request": fetchRequest} = Obj.magic(initial)
 *   …extract identity from req.request.headers…
 * }
 * ```
 */
type contextFactory = initialContext => promise<JSON.t>

@module("graphql-yoga")
external createYoga: {
  "schema": schema,
  "graphiql": bool,
  "logging": bool,
  "maskedErrors": bool,
} => yoga = "createYoga"

/**
 * Variant of `createYoga` that also installs a context factory. Yoga merges
 * the factory's return value into the resolver `context` argument, so
 * authentication adapters (e.g. `Auth_InMemory.authenticate`) can attach an
 * `identity` field that resolvers read off `ctx.identity`.
 */
@module("graphql-yoga")
external createYogaWithContext: {
  "schema": schema,
  "graphiql": bool,
  "logging": bool,
  "maskedErrors": bool,
  "context": contextFactory,
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

// ─── PubSub (for WebSocket subscriptions) ────────────────────────────────

/**
 * An opaque graphql-yoga PubSub instance.
 * Created with `createPubSub()` and shared between the subscription resolver
 * and any code that publishes state changes or events.
 */
type pubSub

/**
 * Creates a new PubSub instance.
 * Exposes `publish(topic, payload)` and `subscribe(topic)` (returns AsyncIterable).
 * One instance per server is sufficient — topic names disambiguate channels.
 */
@module("graphql-yoga")
external createPubSub: unit => pubSub = "createPubSub"

/** Publish a payload to all active subscribers of `topic`. */
@send external pubSubPublish: (pubSub, string, JSON.t) => unit = "publish"

/**
 * Subscribe to `topic`. Returns an `AsyncIterable<JSON.t>` that the
 * subscription resolver's `subscribe` function returns to graphql-yoga.
 * Typed as `'a` so it can be passed directly to the yoga resolver machinery
 * without an intermediate binding for AsyncIterable.
 */
@send external pubSubSubscribe: (pubSub, string) => 'a = "subscribe"
