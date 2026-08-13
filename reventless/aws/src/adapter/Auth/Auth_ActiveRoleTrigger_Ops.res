// Runtime handler for the Cognito **pre token generation** trigger — the AWS
// minting point for "acting as one of the roles you hold". See
// [docs/plans/active-role-narrows-the-token.md] §6.
//
// Compiled, type-checked and Pulumi-free so it ships as an EntryPoint module
// ([Auth_ActiveRoleTrigger.res] bundles it and attaches it to the user pool).
//
// The narrowing has to happen here rather than in our own enforcement code
// because `@authorize(AllowGroups([...]))` compiles to `@aws_auth`, which AppSync
// evaluates against `cognito:groups` **before any of our code executes**. A
// request header we invent could scope reads correctly and still leave every
// group-gated mutation callable — right about the data, wrong about the writes.
// Overriding the group claim is the one place every enforcement point already
// looks.
//
// **Version 1 of the trigger, deliberately.** Group override and added ID-token
// claims are `V1_0` capabilities; `V2_0`/`V3_0` buy access-token customisation
// this does not need and are gated behind the Essentials and Plus feature plans.
// A deployment on the Lite tier must not be excluded from acting as a role.

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

// ── Cognito pre-token-generation event (V1_0) ───────────────────────────────

type userAttributes = {sub?: string}

/** The groups the pool says the user is really in, supplied by the pool itself.
  This is why the subset check here needs no lookup and no IAM to perform one:
  the authority arrives in the payload, and the check is a containment test
  against it. */
type groupConfiguration = {
  groupsToOverride?: array<string>,
  iamRolesToOverride?: array<string>,
  preferredRole?: Nullable.t<string>,
}

type triggerRequest = {
  userAttributes?: userAttributes,
  groupConfiguration?: groupConfiguration,
}

type groupOverrideDetails = {
  groupsToOverride: array<string>,
  iamRolesToOverride: array<string>,
  preferredRole?: Nullable.t<string>,
}

type claimsOverrideDetails = {
  claimsToAddOrOverride?: dict<string>,
  groupOverrideDetails?: groupOverrideDetails,
}

type triggerResponse = {claimsOverrideDetails?: claimsOverrideDetails}

type event = {
  request?: triggerRequest,
  response?: triggerResponse,
  userName?: string,
}

// ── The decision ────────────────────────────────────────────────────────────

type decision =
  /** No stored preference — mint exactly the token that would have been minted
    before any of this existed. This is the path every existing caller takes. */
  | Unchanged
  /** The stored role is one the pool says the caller holds. */
  | Narrow({role: string, membership: array<string>})
  /** The row outlived the membership that justified it.

    Resolved by minting the full set rather than narrowing to a group the pool no
    longer grants — but *decided* here rather than falling out of the code,
    because the alternative reading is a token scoped to a role the caller has
    lost. Unlike the write door, this path has no client to refuse: the trigger
    meets a stale row on an ordinary refresh with nobody asking for anything. It
    says so on the token instead, so a caller whose chosen role silently stopped
    applying has something to read. */
  | Stale({role: string, membership: array<string>})

let decide = (~membership: array<string>, ~storedRole: option<string>): decision =>
  switch storedRole {
  | None | Some("") => Unchanged
  | Some(role) =>
    membership->Array.includes(role) ? Narrow({role, membership}) : Stale({role, membership})
  }

/**
Turn a decision into the trigger's response.

🚨 **`groupOverrideDetails` replaces the whole group configuration.** Supplying it
with only `groupsToOverride` drops the caller's `iamRolesToOverride` and
`preferredRole` — the same reset-by-omission hazard `UpdateUserPool` has, and just
as quiet. Both are echoed from the incoming configuration so the override changes
exactly one thing.

`Unchanged` returns the event untouched rather than an empty override: an empty
`claimsOverrideDetails` is not the same as none, and the regression line for this
whole feature is that a caller with no stored role gets byte-identical output.
*/
let respond = (~event: event, ~decision: decision): event => {
  let incoming = event.request->Option.flatMap(r => r.groupConfiguration)
  let iamRolesToOverride = incoming->Option.flatMap(g => g.iamRolesToOverride)->Option.getOr([])
  let preferredRole = incoming->Option.flatMap(g => g.preferredRole)

  let overrideWith = (~groups: array<string>, ~claims: dict<string>) => {
    ...event,
    response: {
      claimsOverrideDetails: {
        claimsToAddOrOverride: claims,
        groupOverrideDetails: {
          groupsToOverride: groups,
          iamRolesToOverride,
          preferredRole: ?preferredRole,
        },
      },
    },
  }

  switch decision {
  | Unchanged => event
  | Narrow({role, membership}) =>
    overrideWith(
      ~groups=[role],
      ~claims=Dict.fromArray([
        (ReventlessCore.Auth_ActiveRole.activeRoleClaim, role),
        (ReventlessCore.Auth_ActiveRole.availableRolesClaim, membership->Array.join(",")),
      ]),
    )
  | Stale({role, membership}) =>
    // The full set, as the pool granted it — plus the marker that explains why the
    // stored choice did not apply.
    overrideWith(
      ~groups=membership,
      ~claims=Dict.fromArray([
        (ReventlessCore.Auth_ActiveRole.staleRoleClaim, role),
        (ReventlessCore.Auth_ActiveRole.availableRolesClaim, membership->Array.join(",")),
      ]),
    )
  }
}

// ── Stored preference ───────────────────────────────────────────────────────

/**
The role this subject last chose, or `None` if they never chose one or cleared it.

A read failure resolves to `None`, not to an error. This trigger sits in the
critical path of every token Cognito mints for this pool: a throw here fails the
sign-in outright, and failing a login because a *preference* could not be read
trades a working session for a cosmetic one. The caller lands on full membership —
their existing privileges, not more — which is the safe direction to fail.
*/
let storedRoleFor = async (~sub: string, ~table: string): option<string> =>
  try {
    let out = await DynamoDb_DocumentClient.GetCommand.make({
      tableName: table,
      key: Dict.fromArray([("id", JSON.Encode.string(sub))]),
    })->DynamoDb_DocumentClient.GetCommand.send
    out.item
    ->Option.flatMap(JSON.Decode.object)
    ->Option.flatMap(o => o->Dict.get("activeRole"))
    ->Option.flatMap(JSON.Decode.string)
  } catch {
  | _ => None
  }

// ── Handler ─────────────────────────────────────────────────────────────────

let handler = async (event: event): event => {
  let membership =
    event.request
    ->Option.flatMap(r => r.groupConfiguration)
    ->Option.flatMap(g => g.groupsToOverride)
    ->Option.getOr([])

  let sub =
    event.request->Option.flatMap(r => r.userAttributes)->Option.flatMap(u => u.sub)->Option.getOr("")

  // No subject means no row to look up. Returning the event untouched keeps the
  // sign-in working on exactly the membership the pool granted.
  if sub == "" {
    event
  } else {
    let storedRole = await storedRoleFor(~sub, ~table=tableName())
    respond(~event, ~decision=decide(~membership, ~storedRole))
  }
}
