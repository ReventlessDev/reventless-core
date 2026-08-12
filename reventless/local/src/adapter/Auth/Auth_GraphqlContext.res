// Yoga context factory that translates the incoming Fetch Request into an
// `identity` attached to resolver context. Shared between
// `DomainGraphQL_Server` (data API) and `GraphQL_ServerInstance` (split-mode
// admin API) so both endpoints enforce identical bearer-token rules:
//   - Valid `Authorization: Bearer <token>` → signed-in identity
//   - Missing header                       → `defaultUser`
//   - Invalid bearer is rejected at HTTP level before this runs (see
//     `DomainGraphQL_Server._dispatch`); on the admin server there is no
//     dispatch layer, so an invalid bearer falls through to `defaultUser`
//     too. AppSync enforces the same `@aws_auth(cognito_groups: ["Admin"])`
//     directive at the schema layer in production.

module YG = GraphqlYoga

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
  let result = await LocalAuth.authenticate(requestContext)
  let identity = identityFromAuthResult(result)
  Obj.magic({"identity": identity})
}

// Read the identity attached by `buildAuthContext` from the resolver context.
// Falls back to `anonymous` if the context is malformed or the server wasn't
// started with `~contextFactory`.
let extractIdentity = (ctx: JSON.t): Reventless.Identity.t =>
  try {
    switch (ctx->Obj.magic)["identity"]->Nullable.toOption {
    | Some(id) => (id: Reventless.Identity.t)
    | None => Reventless.Identity.anonymous
    }
  } catch {
  | _ => Reventless.Identity.anonymous
  }

// An unauthorized caller reads the reason: `GraphQL_CallerError` explains why a
// resolver has to construct the error rather than throw a bare one. Mirrors the
// directive-level `@aws_auth` rejection that AppSync surfaces in production.
let makeGraphqlError = GraphQL_CallerError.make

let unauthorizedError = (~group: string): exn =>
  makeGraphqlError(
    `Unauthorized: requires group "${group}"`,
    {"extensions": {"code": "UNAUTHORIZED"}},
  )

// Wrap a resolver so it raises a GraphQL "Unauthorized" error when the
// requesting identity lacks the required group. Mirrors AppSync's
// `@aws_auth(cognito_groups: [...])` semantics for admin fields on the
// in-memory adapter. Use for fields whose corresponding read-model entry
// carries `authorization: Some({group, ...})` — pass the group string here.
let requireGroup = (~group: string, resolver: YG.resolverFn): YG.resolverFn =>
  async (root, args, ctx) => {
    let identity = extractIdentity(ctx)
    if identity.groups->Array.includes(group) {
      await resolver(root, args, ctx)
    } else {
      throw(unauthorizedError(~group))
    }
  }
