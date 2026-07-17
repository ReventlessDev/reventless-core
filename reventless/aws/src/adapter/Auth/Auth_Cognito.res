// AWS Cognito `Auth_Adapter.Provider` implementation.
//
// Two runtime entry points:
//
//   * `authenticate` — pure header-driven path (HTTP Lambda Function URL,
//     API Gateway, MCP). Decodes the JWT claims from the
//     `Authorization: Bearer <token>` header WITHOUT signature verification.
//     The Cognito-authenticated AppSync API verifies the JWT before the
//     resolver Lambda runs, so this path trusts the caller's transport
//     guarantees.
//
//   * `fromAppSyncIdentity` — AppSync-resolver path. Reads the
//     already-validated identity context attached by AppSync to the
//     resolver event (`event.identity`). Recognises both the Cognito
//     UserPool shape (`sub`, `username`, `claims['cognito:groups']`) and
//     the AWS_IAM additional-provider shape (`userArn`, `accountId`) used
//     by server-to-server lambdas signed via the existing IAM role.
//
// Deploy-time `make` delegates to `Platform_Stack.resolveCognitoUserPool`
// (cached internally so multiple callers — e.g. a future direct invocation
// from `Platform.MakeWithConfig` plus the existing call from app
// `Main.res` — converge on the same resource set).

open Reventless

// ── Shared JWT claims decode ──────────────────────────────────────────────
//
// AppSync's userPoolConfig verifies the JWT signature on every request
// before invoking the resolver Lambda, so the runtime path only needs to
// read the claims. MCP_Lambda's `extractIdentity` follows the same
// pattern; this implementation is kept compatible.

let _decodeJwtClaims: string => option<'a> = %raw(`
  function(token) {
    try {
      var parts = token.split(".");
      if (parts.length < 2) return undefined;
      var base64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
      var json = Buffer.from(base64, "base64").toString("utf8");
      return JSON.parse(json);
    } catch(_) { return undefined; }
  }
`)

let _bearerToken = (header: string): option<string> =>
  if header->String.startsWith("Bearer ") {
    Some(header->String.slice(~start=7, ~end=header->String.length)->String.trim)
  } else {
    None
  }

let _getHeader = (headers: dict<string>, name: string): option<string> =>
  // Headers are normalised to lowercase by transport adapters before reaching
  // the provider (graphql-yoga and AppSync Lambda integration both do this).
  // We tolerate either case here.
  switch headers->Dict.get(name->String.toLowerCase) {
  | Some(v) => Some(v)
  | None => headers->Dict.get(name)
  }

let _identityFromClaims = (claims: 'a): Identity.t => {
  let claimsDict: dict<JSON.t> = claims->Obj.magic
  let userId =
    claimsDict
    ->Dict.get("sub")
    ->Option.flatMap(JSON.Decode.string)
    ->Option.getOr("anonymous")
  let username =
    claimsDict
    ->Dict.get("cognito:username")
    ->Option.orElse(claimsDict->Dict.get("username"))
    ->Option.flatMap(JSON.Decode.string)
    ->Option.getOr(userId)
  let groups: array<string> =
    claimsDict
    ->Dict.get("cognito:groups")
    ->Option.map(g => g->Obj.magic)
    ->Option.getOr([])
  {
    Identity.userId,
    username,
    groups,
    provider: Cognito,
  }
}

// ── Provider implementation ───────────────────────────────────────────────

type authConfig = {
  userPoolId: string,
  userPoolArn: string,
  clientId: string,
  region: string,
}

let authenticate = async (
  ctx: ReventlessCore.Auth_Adapter.requestContext,
): Identity.authResult => {
  let token =
    _getHeader(ctx.headers, "Authorization")->Option.flatMap(_bearerToken)
  switch token {
  | None => Anonymous
  | Some(t) =>
    switch _decodeJwtClaims(t) {
    | None => AuthError("malformed bearer token")
    | Some(claims) => Authenticated(_identityFromClaims(claims))
    }
  }
}

// ── AppSync resolver-event path ───────────────────────────────────────────
//
// AppSync resolver Lambdas receive `event.identity` already populated with
// validated identity data. For the Cognito User Pools auth path the shape is
// `{sub, username, claims, issuer, sourceIp, defaultAuthStrategy, groups?}`.
// For the AWS_IAM additional-provider path the shape is
// `{userArn, accountId, cognitoIdentityPoolId?, cognitoIdentityId?, sourceIp,
// username, userArn}`. The two are disambiguated by the presence of `sub`.

type appSyncIdentity = {
  sub?: string,
  username?: string,
  claims?: dict<JSON.t>,
  issuer?: string,
  userArn?: string,
  accountId?: string,
}

/** Build an `Identity.authResult` from the AppSync resolver event identity
    block. Pass `event.identity` directly (or `None` if absent). */
let fromAppSyncIdentity = (id: option<appSyncIdentity>): Identity.authResult =>
  switch id {
  | None => Anonymous
  | Some(identity) =>
    switch identity.sub {
    | Some(sub) =>
      // Cognito User Pools — read claims, fall back to top-level fields when
      // the gateway omitted `claims` (e.g. APPSYNC_JS pipelined invocations).
      let rawClaims = identity.claims->Option.getOr(Dict.make())
      let username =
        rawClaims
        ->Dict.get("cognito:username")
        ->Option.orElse(rawClaims->Dict.get("username"))
        ->Option.flatMap(JSON.Decode.string)
        ->Option.orElse(identity.username)
        ->Option.getOr(sub)
      let groups: array<string> =
        rawClaims
        ->Dict.get("cognito:groups")
        ->Option.map(g => g->Obj.magic)
        ->Option.getOr([])
      // Identity.claims is `dict<string>` — stringify any non-string JSON
      // value so the shape downstream consumers see is uniform.
      let claims =
        rawClaims
        ->Dict.toArray
        ->Array.map(((k, v)) => (
          k,
          v->JSON.Decode.string->Option.getOr(v->JSON.stringify),
        ))
        ->Dict.fromArray
      Authenticated({
        userId: sub,
        username,
        groups,
        claims,
        provider: Cognito,
      })
    | None =>
      switch identity.userArn {
      | Some(arn) =>
        // AWS_IAM additional-provider — server-to-server. Encode the role
        // ARN as userId and tag with a `Custom("aws-iam")` provider so
        // downstream authorization can distinguish from human Cognito users.
        Authenticated({
          userId: arn,
          username: identity.username->Option.getOr(arn),
          groups: [],
          provider: Custom("aws-iam"),
        })
      | None => Anonymous
      }
    }
  }

// ── Deploy-time wiring ────────────────────────────────────────────────────
//
// `Platform_Stack.resolveCognitoUserPool` performs the actual UserPool +
// UserPoolClient provisioning and exports the resulting ids/arn/region as
// stack outputs. It caches its result internally so this can be called from
// both `Main.res` and `Auth_Cognito.make` (e.g. Stage D2 AppSync wiring)
// without re-running resource registration or duplicating exports.

let make = (
  ~name as _: string,
  ~opts as _: option<Pulumi.ComponentResource.options>=?,
): Pulumi.Output.t<authConfig> => {
  let pool = Platform_Stack.resolveCognitoUserPool()
  let regionStr =
    Pulumi.Config.make(Some("aws"))->Pulumi.Config.get("region")->Option.getOr("unknown")
  (pool.poolId, pool.poolArn, pool.clientId)
  ->Pulumi.Output.all3
  ->Pulumi.Output.apply(((userPoolId, userPoolArn, clientId)) => {
    userPoolId,
    userPoolArn,
    clientId,
    region: regionStr,
  })
}
