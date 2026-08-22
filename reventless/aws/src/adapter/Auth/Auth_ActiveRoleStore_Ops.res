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

🚨 **Addressed by username, not by `sub`.** `AdminListGroupsForUser` takes a
`Username`, and a `sub` is only accepted there when the pool makes it one — a
pool with `UsernameAttributes` (email or phone sign-in), where the generated
username *is* the subject. On a plain username pool the same call answers
`UserNotFoundException: User does not exist.`, which fails the whole mutation
before it reaches the subset check: not "you may not act as that role" but "you
do not exist", for a caller who is signed in and holds the role. The row is still
keyed on `sub` — this parameter names the user to Cognito, nothing else.

Paginated deliberately: `AdminListGroupsForUser` caps a page at 60 groups, and a
truncated read would silently refuse a role the caller genuinely holds.
*/
let membershipOf = async (~username: string, ~poolId: string): array<string> => {
  let collected = []
  let nextToken = ref(None)
  let more = ref(true)
  while more.contents {
    let page = await CognitoIdentityServiceProvider.AdminListGroupsForUserCommand.make({
      username,
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

type identity = {
  sub?: string,
  username?: Nullable.t<string>,
  /** The app client the caller's token was minted for — the second half of the
    row key. `Null` when the resolver could not read it from the claims. */
  clientId?: Nullable.t<string>,
}
type activeRoleArgs = {activeRole?: Nullable.t<string>}
type appSyncEvent = {
  arguments?: activeRoleArgs,
  identity?: identity,
}

/**
The name to address this caller by when asking Cognito what groups they are in.

The username when the authorizer supplied one, the subject otherwise. The
fallback is not a guess at a username: it is the behaviour this handler had
before the username was forwarded, kept for the pool shapes where it is correct —
one whose username *is* the subject — rather than turning a working deployment
into a hard failure on an absent field. Pure so the choice can be tested without
a pool.
*/
let cognitoLookupName = (~identity: identity): option<string> =>
  switch identity.username {
  | Some(Value(name)) if name->String.trim != "" => Some(name)
  | _ =>
    switch identity.sub {
    | Some("") | None => None
    | Some(sub) => Some(sub)
    }
  }

/**
The app client this row belongs to, completing the key alongside the subject.

🚨 **No fallback, deliberately — this refuses instead of guessing.** Every other
absent field in this handler has a defensible default; this one does not. The
pre-token trigger keys its read on the client id Cognito hands it, so a write
under any substitute — a constant, the subject, the empty string — is a row the
trigger will never find: a switch that reports success and does nothing, which is
the exact defect this store was repaired for. A caller told "we could not
determine which application you are signed in to" has something to act on; a
caller whose switch silently fails does not.

Reachable when the authorizer omits `claims`, which happens on some APPSYNC_JS
invocation shapes — see `Auth_Cognito.fromAppSyncIdentity`, which documents the
same gap and falls back for fields where falling back is safe.
*/
let appClientId = (~identity: identity): option<string> =>
  switch identity.clientId {
  | Some(Value(id)) if id->String.trim != "" => Some(id)
  | _ => None
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
  // Two names for one caller, and they are not interchangeable: `sub` keys the
  // row, the lookup name addresses Cognito. See `membershipOf`.
  let lookupName = switch event.identity->Option.flatMap(i => cognitoLookupName(~identity=i)) {
  | Some(name) => name
  | None => JsError.throwWithMessage("unauthenticated")
  }
  // Refused rather than defaulted — see `appClientId`. The row is keyed on the
  // pair, and half a key is not a key.
  let clientId = switch event.identity->Option.flatMap(i => appClientId(~identity=i)) {
  | Some(id) => id
  | None =>
    JsError.throwWithMessage(
      "Cannot determine which application this session belongs to, so the active role cannot be stored where the token minter will look for it",
    )
  }
  let table = tableName()
  let membership = await membershipOf(~username=lookupName, ~poolId=userPoolId())

  // An absent argument and an explicit `null` mean the same thing — clear the
  // preference and go back to full membership on the next refresh. That is not an
  // escalation: the set being widened to is the one Cognito says the caller holds.
  let requested = switch event.arguments->Option.flatMap(a => a.activeRole) {
  | Some(Value(role)) => Some(role)
  | Some(Null) | Some(Undefined) | None => None
  }

  switch requested {
  | None =>
    // Clears this platform's preference only. A caller acting as a role in
    // another platform on the same provider keeps it — which is the point of the
    // pair key, and would be surprising if the clear were pool-wide.
    let _ = await DynamoDb_DocumentClient.deleteByIdSort(
      ~tableName=table,
      ~id=sub,
      ~sortField=Auth_ActiveRoleStore_Schema.sortKey,
      ~sortKey=clientId,
    )
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
        (Auth_ActiveRoleStore_Schema.partitionKey, JSON.Encode.string(sub)),
        (Auth_ActiveRoleStore_Schema.sortKey, JSON.Encode.string(clientId)),
        (Auth_ActiveRoleStore_Schema.roleAttribute, JSON.Encode.string(role)),
        ("updatedAt", JSON.Encode.string(Date.make()->Date.toISOString)),
      ])->JSON.Encode.object
    let _ = await DynamoDb_DocumentClient.PutCommand.make({
      tableName: table,
      item,
    })->DynamoDb_DocumentClient.PutCommand.send
    result(~activeRole=Some(role), ~availableRoles=membership)
  }
}
