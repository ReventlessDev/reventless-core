// Platform (admin-facing) in-memory GraphQL server — singleton.
// Serves admin/core operations on a separate port in split mode (port 4001).
//
// Uses the same ReventlessGraphqlServer.GraphQL_ServerInstance factory as the generic instance,
// but is exposed as a named singleton so Platform.res can reference it
// directly (mirroring the AWS PlatformAPI resource pattern).
//
// Does NOT include Relay-specific features (encodeGlobalId, node resolver)
// since admin queries are not Relay-paginated.
//
// Authorization: every query, mutation AND subscription resolver registered
// here is wrapped with `Auth_GraphqlContext.requireGroup(~group="Admin")` so
// non-Admin identities are refused before the underlying resolver runs.
// Mirrors AppSync's `@aws_cognito_user_pools(cognito_groups: ["Admin"])`
// directive that gates Platform_* fields in the AWS adapter.
//
// The refusal names which kind it is: `FORBIDDEN` for a caller the server
// identified who does not hold the group, `UNAUTHORIZED` for one it could not
// identify at all. Every surface here is admin-gated, so a client discovering
// through them meets this refusal as a matter of course rather than as a
// failure, and cannot afford to read it as a session that has ended.
//
// Mutations are wrapped (in addition to their per-command
// `authorizationOf` rule inside `CommandGeneratorResolvers_GraphQL.register`)
// because the per-command rule defaults to `AllowAuthenticated` and the
// in-memory adapter falls back to `defaultUser` on missing-bearer requests
// — without the wrapper, anonymous callers could trigger admin mutations
// (Plugin_Activate / _Deactivate, etc.) just by hitting the platform port.

let instance: ReventlessGraphqlServer.GraphQL_ServerInstance.t = ReventlessGraphqlServer.GraphQL_ServerInstance.make(
  ~label="GraphQL:Platform",
)

// Wrap a resolver dict so every value enforces the Admin group. Keys are
// preserved; resolvers fall through to the underlying instance once the
// group check passes.
let wrapAdmin = (resolvers: dict<ReventlessGraphqlServer.GraphQL_ServerInstance.resolverFn>): dict<
  ReventlessGraphqlServer.GraphQL_ServerInstance.resolverFn,
> => {
  let wrapped = Dict.make()
  resolvers
  ->Dict.toArray
  ->Array.forEach(((k, v)) =>
    wrapped->Dict.set(k, Auth_GraphqlContext.requireGroup(~group=Reventless.Role.adminGroup(), v))
  )
  wrapped
}

// A subscription field's resolver is an object: `subscribe` starts the stream,
// `resolve` maps each payload. The group check goes on `subscribe`, so a caller
// without the group is refused before anything is streamed to it.
type subscriptionResolver = {
  subscribe: ReventlessGraphqlServer.GraphQL_ServerInstance.resolverFn,
  resolve?: JSON.t => JSON.t,
}
external asSubscription: ReventlessGraphqlServer.GraphQL_ServerInstance.resolverFn => subscriptionResolver =
  "%identity"
external ofSubscription: subscriptionResolver => ReventlessGraphqlServer.GraphQL_ServerInstance.resolverFn =
  "%identity"

let wrapAdminSubscriptions = (
  resolvers: dict<ReventlessGraphqlServer.GraphQL_ServerInstance.resolverFn>,
): dict<ReventlessGraphqlServer.GraphQL_ServerInstance.resolverFn> =>
  resolvers
  ->Dict.toArray
  ->Array.map(((k, v)) => {
    let sub = asSubscription(v)
    (
      k,
      ofSubscription({
        ...sub,
        subscribe: Auth_GraphqlContext.requireGroup(
          ~group=Reventless.Role.adminGroup(),
          sub.subscribe,
        ),
      }),
    )
  })
  ->Dict.fromArray

let registerMutations = (~sdlFields, ~resolvers) =>
  instance.registerMutations(~sdlFields, ~resolvers=wrapAdmin(resolvers))
let registerQueries = (~sdlFields, ~resolvers) =>
  instance.registerQueries(~sdlFields, ~resolvers=wrapAdmin(resolvers))
let registerSubscriptions = (~sdlFields, ~resolvers) =>
  instance.registerSubscriptions(~sdlFields, ~resolvers=wrapAdminSubscriptions(resolvers))
let registerTypes = instance.registerTypes
// Not admin-wrapped: a field resolver is only reached through a parent field
// that already met the group check, so wrapping would re-refuse a caller the
// root already admitted.
let registerFieldResolvers = instance.registerFieldResolvers
let getMutationResolver = instance.getMutationResolver
let getQueryResolver = instance.getQueryResolver
let start = instance.start
let stop = instance.stop
let reset = instance.reset
let buildSdl = instance.buildSdl
let getFullSdl = instance.getFullSdl
let getSchema = instance.getSchema
let diagnostics = instance.diagnostics
let printDiagnostics = instance.printDiagnostics

// Expose as ReventlessGraphqlServer.GraphQL_ServerInstance.t for resolveTargetGraphQL() in Platform.res.
// `registerQueries` is the wrapped version so admin auth fires regardless of
// whether callers reach the singleton directly or through `asInterface`.
let asInterface: ReventlessGraphqlServer.GraphQL_ServerInstance.t = {
  registerMutations,
  registerQueries,
  registerSubscriptions,
  registerTypes,
  registerFieldResolvers,
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
