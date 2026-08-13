// Runtime handler for `Mutation.Platform_SetActiveRole` — compiled, type-checked
// and Pulumi-free so it ships as an EntryPoint module (`Auth_ActiveRoleStore`
// bundles it and attaches it as the domain API's Lambda data source). See
// [Upload_Presign_S3_Ops.res] for why an EntryPoint rather than a serialized
// closure, and [docs/plans/active-role-narrows-the-token.md] §6 for the design.
//
// What this writes is a *preference*, not a token. Cognito mints the token, and
// the pre-token-generation trigger ([Auth_ActiveRoleTrigger_Ops.res]) reads this
// row on the next refresh and narrows the group claim to it. Nothing here can
// grant anything: the trigger re-checks the stored role against real membership
// before applying it, so a row is at most a request that the trigger may honour.
//
// 🚨 **The subject is taken from the verified identity, never from the arguments.**
// The row key is `ctx.identity.sub` as the AppSync Cognito authorizer resolved it.
// There is deliberately no `sub` argument on the mutation — with one, a caller
// could set another caller's role, and this becomes a privilege-granting surface
// instead of a preference.

open AwsSdk

// ── Environment ─────────────────────────────────────────────────────────────

let getEnv = (k: string): option<string> =>
  switch NodeProcess.env->Dict.get(k) {
  | Some("") | None => None
  | Some(v) => Some(v)
  }

let tableName = (): string =>
  switch getEnv("ACTIVE_ROLE_TABLE") {
  | Some(t) => t
  | None => JsError.throwWithMessage("ACTIVE_ROLE_TABLE is not configured")
  }

let userPoolId = (): string =>
  switch getEnv("COGNITO_USER_POOL_ID") {
  | Some(p) => p
  | None => JsError.throwWithMessage("COGNITO_USER_POOL_ID is not configured")
  }

// ── Membership ──────────────────────────────────────────────────────────────

/**
The caller's actual group membership, read from Cognito.

🚨 **Not read from the presented token.** A narrowed token carries exactly one
group, so judging membership by `ctx.identity.groups` would make the switch
one-way: a caller who narrowed to `Shopper` could never widen back, because the
token they hold no longer mentions the role they are asking for. This is the same
trap the local path documents on `LocalAuth.Login.reissue`, where membership is
re-read from the user store rather than from the token's own record of it.

Paginated deliberately: `AdminListGroupsForUser` caps a page at 60 groups, and a
truncated read would silently refuse a role the caller genuinely holds.
*/
let membershipOf = async (~sub: string, ~poolId: string): array<string> => {
  let collected = []
  let nextToken = ref(None)
  let more = ref(true)
  while more.contents {
    let page = await CognitoIdentityServiceProvider.AdminListGroupsForUserCommand.make({
      username: sub,
      userPoolId: poolId,
      nextToken: ?nextToken.contents,
    })->CognitoIdentityServiceProvider.AdminListGroupsForUserCommand.send
    page.groups
    ->Option.getOr([])
    ->Array.forEach(g => g.groupName->Option.forEach(n => collected->Array.push(n)))
    switch page.nextToken {
    | Some(_) as t => nextToken := t
    | None => more := false
    }
  }
  collected
}

// ── The subset rule ─────────────────────────────────────────────────────────

/**
Whether a requested role may be stored.

Narrowing only, never widening — a client that tampers with the request can only
ever reduce its own privilege. Pure and exported so the conformance table in
`ReventlessCore.Auth_ActiveRole` can be driven against it without a Cognito pool
or a DynamoDB table in existence.
*/
let mayActAs = (~membership: array<string>, ~requested: string): bool =>
  membership->Array.includes(requested)

// ── AppSync resolver event / result shapes ──────────────────────────────────

type identity = {sub?: string}
type activeRoleArgs = {activeRole?: Nullable.t<string>}
type appSyncEvent = {
  arguments?: activeRoleArgs,
  identity?: identity,
}

let result = (~activeRole: option<string>, ~availableRoles: array<string>): JSON.t =>
  Dict.fromArray([
    ("activeRole", activeRole->Option.mapOr(JSON.Null, JSON.Encode.string)),
    ("availableRoles", availableRoles->Array.map(JSON.Encode.string)->JSON.Encode.array),
  ])->JSON.Encode.object

// ── Handler ─────────────────────────────────────────────────────────────────

let handler = async (event: appSyncEvent): JSON.t => {
  let sub = event.identity->Option.flatMap(i => i.sub)->Option.getOr("")
  if sub == "" {
    // The authorizer should have refused first; this is the guard that keeps an
    // unauthenticated path from ever writing a row keyed on the empty subject.
    JsError.throwWithMessage("unauthenticated")
  }
  let table = tableName()
  let membership = await membershipOf(~sub, ~poolId=userPoolId())

  // An absent argument and an explicit `null` mean the same thing — clear the
  // preference and go back to full membership on the next refresh. That is not an
  // escalation: the set being widened to is the one Cognito says the caller holds.
  let requested = switch event.arguments->Option.flatMap(a => a.activeRole) {
  | Some(Value(role)) => Some(role)
  | Some(Null) | Some(Undefined) | None => None
  }

  switch requested {
  | None =>
    let _ = await DynamoDb_DocumentClient.deleteById(~tableName=table, ~id=sub)
    result(~activeRole=None, ~availableRoles=membership)
  | Some(role) =>
    // Refused, specifically — not ignored and stored anyway. A client asking for
    // something it cannot have is either confused or hostile, and both are better
    // served by an error than by a stored role that quietly never takes effect.
    if !mayActAs(~membership, ~requested=role) {
      JsError.throwWithMessage(`Cannot act as "${role}": not a group this user holds`)
    }
    let item =
      Dict.fromArray([
        ("id", JSON.Encode.string(sub)),
        ("activeRole", JSON.Encode.string(role)),
        ("updatedAt", JSON.Encode.string(Date.make()->Date.toISOString)),
      ])->JSON.Encode.object
    let _ = await DynamoDb_DocumentClient.PutCommand.make({
      tableName: table,
      item,
    })->DynamoDb_DocumentClient.PutCommand.send
    result(~activeRole=Some(role), ~availableRoles=membership)
  }
}
