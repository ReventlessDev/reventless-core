// Yoga context factory that translates the incoming Fetch Request into an
// `identity` attached to resolver context. Shared between
// `DomainGraphQL_Server` (data API) and `GraphQL_ServerInstance` (split-mode
// admin API) so both endpoints enforce identical bearer-token rules:
//   - Valid `Authorization: Bearer <token>` → signed-in identity
//   - Missing header                       → `defaultUser`
//   - Invalid bearer is rejected at HTTP level before this runs (see
//     `DomainGraphQL_Server._dispatch`); on the admin server there is no
//     dispatch layer, so an invalid bearer reaches this as an `AuthError`.
//     AppSync enforces the same `@aws_cognito_user_pools(cognito_groups:
//     ["Admin"])` directive at the schema layer in production.
//
// The outcome is carried onto the context beside the identity, not folded into
// it. Whether credentials verified and whether the verified caller holds a group
// are different questions with different answers for the client — one is worth
// retrying with new credentials, the other never is — and a group check that
// sees only the identity cannot tell which one it is refusing.

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

/**
 Whether the request presented credentials the adapter accepted.

 `identityFromAuthResult` cannot answer this: it maps both `Anonymous` and
 `AuthError` onto the same anonymous identity, so by the time a resolver holds
 an identity, "nobody presented credentials", "the credentials did not verify"
 and "credentials verified for someone without the group" are one shape. That
 collapse is what made a group check unable to say which of them it was
 refusing.

 A request carrying no `Authorization` header at all counts as authenticated
 here, because `LocalAuth.authenticate` answers it with `defaultUser` by
 design — in-memory mode decides such a caller is somebody, and this reports
 the decision rather than second-guessing it.
 */
let isAuthenticated = (result: Reventless.Identity.authResult): bool =>
  switch result {
  | Authenticated(_) => true
  | Anonymous | AuthError(_) => false
  }

let buildAuthContext = async (initial: YG.initialContext): JSON.t => {
  let ctx: yogaInitialCtx = Obj.magic(initial)
  let headers = extractHeaders(ctx.request.headers)
  let requestContext: ReventlessCore.Auth_Adapter.requestContext = {headers: headers}
  let result = await LocalAuth.authenticate(requestContext)
  let identity = identityFromAuthResult(result)
  Obj.magic({"identity": identity, "authenticated": isAuthenticated(result)})
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

// Read the authentication outcome `buildAuthContext` recorded. Falls back to
// `false` for the same reasons `extractIdentity` falls back to anonymous, and
// with the same conservatism: a context this cannot read is one that proves
// nothing about the caller, and "unauthenticated" is the answer that asks them
// to present credentials rather than telling them theirs were rejected.
let extractAuthenticated = (ctx: JSON.t): bool =>
  try {
    switch (ctx->Obj.magic)["authenticated"]->Nullable.toOption {
    | Some(authenticated) => (authenticated: bool)
    | None => false
    }
  } catch {
  | _ => false
  }

// An unauthorized caller reads the reason: `GraphQL_CallerError` explains why a
// resolver has to construct the error rather than throw a bare one. The AWS
// counterpart is the field-level refusal AppSync returns for a caller who fails
// an `@aws_cognito_user_pools(cognito_groups: [...])` gate.
let makeGraphqlError = GraphQL_CallerError.make

/**
 Nobody the server could identify asked for a gated field.

 Keeps the code it has always carried. A client reading only `UNAUTHORIZED` is
 one that treats it as "your credentials are not being honoured", and narrowing
 the code to the case where that is true makes such a client correct rather than
 breaking it.
 */
let unauthorizedError = (~group: string): exn =>
  makeGraphqlError(
    `Unauthorized: requires group "${group}"`,
    {"extensions": {"code": ReventlessCore.Auth_RefusalVocabulary.localIdentityCode}},
  )

/**
 Somebody the server identified asked for a field their groups do not cover.

 Separate from `unauthorizedError` because the two ask for different things and
 a client cannot tell them apart from the refusal alone. Answering both with one
 code left every caller to guess, and the guess that fits an expired token —
 discard the session and ask them to sign in again — ends a working session for
 a caller who was simply not entitled to the field. Presenting credentials again
 cannot change this answer, which is what the distinct code says.
 */
let forbiddenError = (~group: string): exn =>
  makeGraphqlError(
    `Forbidden: requires group "${group}"`,
    {"extensions": {"code": ReventlessCore.Auth_RefusalVocabulary.localEntitlementCode}},
  )

// Wrap a resolver so it refuses a caller whose identity lacks the required
// group. Mirrors AppSync's `@aws_cognito_user_pools(cognito_groups: [...])`
// semantics for admin fields on the in-memory adapter. Both paths draw the same
// two-way distinction — AppSync as HTTP 401 versus a field error, this as two
// `extensions.code` values — and `ReventlessCore.Auth_RefusalVocabulary` is the
// mapping between them. Use for fields whose corresponding read-model entry
// carries `authorization: Some({group, ...})` — pass the group string here.
let requireGroup = (~group: string, resolver: YG.resolverFn): YG.resolverFn =>
  async (root, args, ctx) => {
    let identity = extractIdentity(ctx)
    if identity.groups->Array.includes(group) {
      await resolver(root, args, ctx)
    } else if extractAuthenticated(ctx) {
      throw(forbiddenError(~group))
    } else {
      throw(unauthorizedError(~group))
    }
  }
