# Plan: a caller holding several roles can act as one of them

**Status.** Steps 1, 2 and 2b **built 2026-08-13** on the local path (core
`61141ac78`, `6e8f06a22`) and verified against a running example. Steps 3 and 4
**built 2026-08-13**, unit-tested, and **not yet deploy-verified** — see "What is
still open" below before treating the AWS half as done.

§6 was **rewritten 2026-08-13** before any of it was built. The original design —
a `custom:activeRole` attribute read by the trigger — does not survive contact
with what the service documents: the channel it needed is closed on the refresh
path, and the attribute it wanted is a permanent amendment to the customer's user
pool. What replaced it is smaller and touches the pool once. Read §6 before step
3; the two hazards it names are both quiet ones.

### What step 3 built

| Piece | Where |
| --- | --- |
| Claim names + the conformance table both paths run | `reventless/core/src/adapter/Auth/Auth_ActiveRole.res` |
| Role-state table, and the `Platform_SetActiveRole` write door | `reventless/aws/src/adapter/Auth/Auth_ActiveRoleStore{,_Ops}.res` |
| The pre-token-generation trigger (V1_0) | `reventless/aws/src/adapter/Auth/Auth_ActiveRoleTrigger{,_Ops}.res` |
| BYO attach: describe → merge → update | `reventless/aws/src/adapter/Auth/Auth_ActiveRolePoolAttachment.res` |
| Both pool modes wired, table → trigger → pool | `reventless/aws/src/Platform_Stack.res` |

Three decisions worth carrying forward, none of them foreseen here:

- **The write door re-reads membership from Cognito** (`AdminListGroupsForUser`),
  not from `ctx.identity.groups`. A narrowed token carries one group, so judging
  membership by the token would make the switch one-way — the same trap step 2b
  hit locally, arriving from the other side.
- **Table and trigger are provisioned with the pool, not with the mutation.** The
  pool is declared carrying the trigger's ARN, so table → trigger → pool → API →
  write door is a forced order; provisioning the table beside the mutation closes
  it into a cycle. Both are provisioned unconditionally — see the next section
  for the version of this that did not survive a preview.
- **The merge uses a denylist, not an allowlist.** An allowlist that missed a
  field would omit it and silently reset it — the exact failure §6 flags. A
  denylist that misses a read-only field makes AWS reject the call instead. Given
  the choice between "a customer's pool quietly loses a setting" and "the deploy
  fails loudly", the second is the one to design for.

### What is still open

Everything below is built and unit-tested; none of it has met a live pool.

- **Nothing here has been deployed.** §8's Cognito acceptance list is satisfied
  against the pure decision functions (`decide`/`respond`/`mergedUpdateInput`),
  not against a running pool. The settings-survive-the-attach case is asserted
  against a described pool the test did not create, which is the shape §6 asked
  for — but a real `UpdateUserPool` round trip has not been made.
- **Trigger cold start is unmeasured.** It sits in the critical path of every
  token the pool mints. 256 MB / 5 s is a guess chosen to fail inside Cognito's
  own trigger budget rather than after it.
- **BYO has not been exercised end to end.** The attach resource is the one piece
  that can damage something that already exists. Its *payload* is now verified
  against the live alpha pool (see the dry run below); what has not happened is
  AWS accepting it.

🚨 **The first push runs 3.3 against the real alpha pool, unasked.** The deploy
workflow sets `REVENTLESS_COGNITO_USER_POOL_ID` from a secret
(`.github/workflows/deploy-reventless-aws.yml`), and `Util_LocalConfig.get` gives
the env var precedence over stack config — so every deployed stack is in **BYO
mode**, not auto. The next push therefore fires `Auth_ActiveRolePoolAttachment` —
describe, merge, `UpdateUserPool` — against the live pool, as a side effect of a
push rather than as a deliberate act. That inverts the ordering §7 chose, where
3.3 lands last precisely so the two steps before it make it the only unknown.

Capture the pool's current state **before** pushing, or the merge has nothing to
be checked against afterwards:

```
aws cognito-idp describe-user-pool --user-pool-id <id> > pool-before.json
```

Then diff it against the same call after the deploy. The expected difference is
exactly one added key: `LambdaConfig.PreTokenGeneration`. Any second difference
is the reset-by-omission failure §6 warns about, and it is the kind that succeeds
quietly — nothing errors, a setting simply goes back to its default.

**Dry-run against the live alpha pool, 2026-08-13 — the payload is verified up to
the network call.** `eu-west-1_CQTwafSeX` (`cognitoUserPoolManaged: false`,
confirming BYO) was described, run through `mergedUpdateInput`, and serialised by
`UpdateUserPoolCommand` with the request aborted before the HTTP handler. Results:

- Every one of the 17 `UpdateUserPool` members the pool carries is on the wire —
  `Policies`, `MfaConfiguration`, `DeletionProtection`, `AccountRecoverySetting`,
  `EmailConfiguration`, `VerificationMessageTemplate`, `UserPoolTags`,
  `UserPoolTier`, `UserAttributeUpdateSettings`, `AdminCreateUserConfig`, the
  four message fields, and `PoolName`. Nothing is left to reset.
- `LambdaConfig` gains exactly `PreTokenGeneration`. The pool carries no other
  trigger today, so there is nothing there to preserve either.
- The pool also returns `IssuerConfiguration` and `KeyConfiguration`, which are
  **not** members of `UpdateUserPool`. The merge carries them and the SDK drops
  them during serialisation, so they are harmless — no parameter error.

That last point sharpens why the denylist is the right structure rather than
merely the safer one: the SDK already drops everything that is not a member, so a
denylist **cannot** omit a member, while an allowlist that missed one would omit
it and reset it silently. The fixture in
`Auth_ActiveRolePoolAttachmentTest.res` now mirrors this real key set, including
a paid `UserPoolTier` — a tier reverting to Lite would be a billing- and
capability-level regression that nothing in the deploy would report.

What is still unverified is only AWS's response to that payload, and the trigger
actually firing.

**`pulumi preview` against alpha, 2026-08-13 — and the bug it caught.** The first
preview produced **no active-role resources at all**. The feature would have
deployed as a complete no-op: no error, no resource, nothing to notice, and the
push would have looked like a success.

The cause was a `~withActiveRole` parameter on `resolveCognitoUserPool`, added so
a unified-API platform would not pay a DynamoDB read per sign-in for a preference
nobody can write. But that function is **process-cached**, so the parameter did
not configure the pool — it configured whichever caller resolved the pool first.
`Auth_Cognito.make` reaches it through an adapter record rather than a direct
call (which is why grepping for call sites found two of the six that actually
happen) and arrives *before* the platform's own call, passing the default
`false`. The cache then locked the feature off for every later caller.

The parameter is gone; both resources are now unconditional, and
`resolveCognitoUserPool` carries a note that it must never grow an argument
again. A second preview shows all twelve resources — table, both Lambdas, both
roles, the policies, the log groups, the `lambda:Permission`, the AppSync data
source, the `Platform_SetActiveRole` resolver, and the
`pulumi-nodejs:dynamic:Resource ActiveRolePoolAttachment`.

Two things that preview also proves, which nothing else could:

- **The dynamic provider's closure serialises.** Pulumi writes it into stack
  state at registration; a capture it could not serialise would have failed here.
- **The forced table → trigger → pool ordering resolves without a cycle,** and
  both Lambda code archives build.

The general lesson is worth more than the fix: a cached resolver is not a place
to put a switch. The failure mode of getting it wrong is not an error — it is
absence, and absence is invisible in a deploy log.

Repeat the preview before any future push that touches this area; it costs about
a minute and it is the only check that catches a resource which simply is not
there.

**A V1_0 nuance §8's "identity and access tokens agree" turns on.** Group
override applies to both the ID and the access token, but `claimsToAddOrOverride`
is **ID-token only** — so `activeRole` / `availableRoles` will appear on the ID
token alone. Nothing in the design depends on them being anywhere else: every
enforcement point reads `cognito:groups`, which is overridden in both. But the
acceptance criterion says the two tokens agree, so decode both and confirm it
rather than assuming it. If a consumer ever needs the custom claims on the access
token, that is the one thing `V2_0` buys — and it is gated behind the Essentials
feature plan, which is the trade §6 declined on purpose.

**Sibling plans:**
- `docs/plans/done/curated-manifest-per-journey.md` — what each role *sees*. Independent
  of this one and buildable in either order; this plan decides what a role
  *may do*, which is the half that has to be right.
- `reventless-ui: docs/plans/shell-active-role-switch.md` — the control that asks
  for the narrowing this plan mints.

**Goal.** A user whose account holds several groups can act as one of them, and
every enforcement point in the system agrees with the choice.

**Non-goal.** Revocation. See §5 — this is a safety mechanism, and calling it
anything else would be a lie a reader could act on.

---

## §1 — Why the token, and not a request header

The cheap shape is a header: the client says "treat me as `Shopper`" and our own
enforcement intersects that with the token's groups. It reaches a great deal —
owner-scoped reads, `CommandGenerator_Callback`, the `QueryDb_Callback`
interceptor — and it is still wrong, because what it reaches is not everything
that runs.

`@authorize(AllowGroups(["Admin"]))` compiles to `@aws_auth`. AppSync evaluates
that against `cognito:groups` **before any of our code executes**, so no header we
invent can narrow it. The result is the worst state available: reads correctly
scoped, `addProduct` still callable. A mode that is right about the data and wrong
about the writes is exactly the mode someone will trust for more than it is —
and it fails in the direction where being trusted is the damage.

So the narrowing has to happen where every enforcement point already looks: in
the token's own group claim.

## §2 — What follows for free, and why that is the argument for this order

Nothing downstream needs to learn what a role is. Every layer already keys on the
caller's groups:

| Layer | Reads | After a switch |
| --- | --- | --- |
| Owner-scoped reads (four sites) | `identity.groups` via `OwnerScope` | Narrows — the caller is no longer exempt |
| Command authorization | `cognito:groups` via `@aws_auth` | Refuses — the group is gone from the token |
| Shell discovery and owner-field hiding | token groups ∩ declared elevated groups | Resolve as a scoped caller, correctly |

That is the whole reason to build the narrowing before anything that consumes it.
A design that taught each layer its own notion of "active role" would have to get
the same decision right four times, and the fourth is generated JavaScript in a
resolver template.

## §3 — The rule that carries the security

**The requested role must be a subset of actual membership.** Narrowing only,
never widening, so a client that tampers with the request can only ever reduce
its own privilege.

This is the one line in the feature where a mistake is a vulnerability rather
than a bug, and it should read that way in the source: the check belongs at the
point of minting, before any claim is written, and its test is the one that
asserts a request for a group the user does not hold is refused rather than
honoured, ignored, or silently reduced to the empty set.

Refused, specifically — not "ignored and minted as the full set". A client asking
for something it cannot have is either confused or hostile, and both are better
served by an error than by a token that does not match what was asked for.

## §4 — Local first, and it is nearly free

`/__inmemory/login` already issues and HMAC-verifies its own tokens against
`users.yaml` (`reventless/local/src/adapter/DomainGraphQL_Server.res`,
`LocalAuth.Login.issue`). The narrowed claim is therefore a parameter on minting
rather than new machinery: the body grows an optional `activeRole`, the subset
check runs against the store entry's `groups`, and the issued token carries the
one group instead of all of them.

The identity echoed back in the response has to carry the *narrowed* groups too,
not the full set — the shell reads that response to decide what to show, and a
response disagreeing with the token it accompanies would put the client one step
behind the server from the first request.

Building this half first is worth stating as a decision rather than a
convenience: it is the half with the fast feedback loop, and it makes every
consumer of the narrowing testable before a Cognito trigger exists to be
debugged.

## §5 — What this is not

**Safety, not a security boundary.** A token already issued stays valid until it
expires. Switching narrows the tokens minted *after* it and revokes nothing, so a
caller who kept an earlier token — or a request already in flight — still has the
wider claim until it lapses.

That makes this a mechanism for stopping an operator acting with elevated rights
**by accident**, which is a real and common failure. It is not a mechanism for
containing one who is trying to. Claiming the latter needs short token lifetimes
and a revocation path, which is a different project with different costs.

Document it as the former, in the reference docs and not only here, or it will be
read as the latter by someone who never saw this file.

## §6 — The AWS half

Same rule, different minting point — but the minting point is Cognito's, not
ours, and that changes the shape rather than only the location. This section was
first written as "`custom:activeRole` on the user, plus a trigger that reads it".
Checking it against the service's documented behaviour before building it turned
up two facts that between them replace that design; both are recorded here
because each is cheaper to read than to rediscover.

**The request cannot carry the role.** The obvious design has the client name its
role on the call that mints the token. It does not work: Cognito *"doesn't
include data from the `ClientMetadata` parameter in `AdminInitiateAuth` and
`InitiateAuth` API operations in the request that it passes to the pre token
generation function"* — and `REFRESH_TOKEN_AUTH` is an `InitiateAuth` flow.
`ClientMetadata` reaches the trigger only from the `RespondToAuthChallenge`
pair, which a refresh does not go through. A switch is a refresh, so the channel
that looks purpose-built for this is closed on exactly the path we need.

**Actual membership arrives in the event.** The trigger receives
`request.groupConfiguration.groupsToOverride` — the groups the user is really in,
supplied by the pool itself. §3's subset check therefore needs no lookup and no
IAM to perform one: the authority is already in the payload, and the check is a
containment test against it. This is a stronger position than the local path,
where membership has to be re-read from the store deliberately.

Together those give the design: **the desired role is server-side state, and the
trigger reads it.** A table keyed by the user's `sub`, written through an
authorized platform mutation that can only ever address the caller's own subject,
read by the trigger when it fires.

The gain is not merely that it works. It removes `custom:activeRole` entirely,
and a Cognito custom attribute is a **one-way door** — it can never be removed
or retyped once added to a pool. A design that avoids permanently amending a
customer's user pool to hold a preference is the better design even where the
attribute would have worked.

**Version one of the trigger is enough.** Group override and added ID-token
claims are `V1_0` capabilities; `V2_0` and `V3_0` buy access-token customisation
we do not need and are gated behind the Essentials and Plus feature plans. A
deployment on the Lite tier must not be excluded from acting as a role, so the
trigger stays on `V1_0` deliberately rather than by omission.

### The pool we do not own

`Platform_Stack.resolveCognitoUserPool` has two modes, and this feature meets
them differently. In **auto** mode the framework created the pool and setting
`lambdaConfig.preTokenGeneration` is an ordinary property on a resource we
already declare. In **BYO** mode — `platform:cognitoUserPoolId` supplied, pool
looked up through `getUserPool` for its ARN alone, `managed: false` — we hold no
handle to set anything on.

BYO cannot be treated as the unsupported case. It is the mode a customer with an
existing identity estate will be in, and telling them the framework must own
their user pool before an operator can act as a role is a much larger ask than
the feature is worth.

The trigger is a property of the pool and Cognito offers no separate attachment
resource, so something must call `UpdateUserPool` against a pool no stack owns.
That belongs in a declared resource in this repository, executed at deploy time —
never a hand-run command against a live pool, which would leave the deployment's
behaviour depending on an act no source describes.

🚨 **`UpdateUserPool` resets by omission.** The API requires *"a value for all
parameters that you don't want set to a default value"*. An attach that sends
only `LambdaConfig` silently returns every other setting on that pool to its
default — on a pool the framework did not create and whose configuration it never
described. The resource must `DescribeUserPool`, merge into the response, and
send the result back whole; and its test is the one asserting a pool with
non-default settings still has them afterwards. This is the single most dangerous
step in the feature, and it is dangerous in a way that succeeds quietly.

### What is written twice, and what is shared

The subset check is written twice rather than shared — the trigger runs in
Cognito's own runtime with Cognito's own event shape, and a shared helper
spanning that boundary would be carrying one line of logic across a process
boundary for the appearance of reuse. What must be shared is the **test**: the
same table of (membership, requested, expected) cases, run against both minting
paths, so the two cannot drift on the question that matters.

One case the local path never had to answer: a stored role the user no longer
holds. The row outlives the membership, and the trigger meets it on an ordinary
refresh with no client asking for anything. It resolves the same way a refused
request does — the narrowing does not apply, and the caller mints the full set —
but it must be *decided* here rather than falling out of the code, because the
alternative reading is a token narrowed to a group the pool no longer grants.

## §7 — Steps

1. `activeRole` on the local login body + the subset rule + the narrowed claim,
   with the response identity narrowed to match. Tests: the subset table, and
   that an unnarrowed login is byte-identical to today.
2. A caller-visible way to read the current active role back, so the shell can
   render what it is without inferring it from the group list.
2b. **Re-minting an existing session** — added on contact with the consumer, not
   foreseen here. A switch cannot go through the login path: the client holds a
   token, not a password, and re-prompting would price a navigation as a
   re-authentication. Membership is re-read from the store rather than from the
   presented token, so the record a narrowed token keeps of what it gave up
   never becomes the authority for getting it back.
3. The Cognito path, in the order that keeps each piece testable before the next
   depends on it:
   1. The role-state table and the mutation that writes it, authorized on the
      caller's own subject. Testable with no trigger in existence.
   2. The trigger itself, against the same subset table as step 1, plus the
      stale-role case §6 names. Its event shape is fixed and documented, so it
      is unit-testable before any pool is attached to it.
   3. The attach resource: describe, merge, update — with the
      settings-survive-the-attach test §6 asks for. Last, because it is the step
      that touches a pool the framework may not own, and the two above make it
      the only unknown left when it runs.
4. Reference docs: §5's distinction, stated where someone reading about roles
   will meet it. — **built**, as an "Acting as one of your roles" section on
   `packages/doc/docs-app/common-modules/identity.md`, the page where someone
   reading about groups and claims already is.

Steps 1–2 stand alone and are demonstrable locally. Step 3 is independent of
everything downstream, and its three parts are worth landing separately — 3.3 is
the only one that can damage something that already exists.

## §8 — Acceptance

- A login that names no active role mints exactly the token it mints today.
- A login naming a group the user holds mints a token carrying that group alone,
  and an identity in the response that says the same.
- A login naming a group the user does **not** hold is refused, and the refusal
  says so rather than falling back to a full-membership token.
- With a narrowed token: an owner-scoped list returns only the caller's rows, and
  a command the surrendered group authorized is refused by the API — not merely
  absent from a menu.
- The same three minting cases hold on both paths.

On the Cognito path specifically:

- A refresh with no stored role mints exactly the token it mints today.
- A refresh with a stored role the user holds narrows `cognito:groups` to it, and
  the identity and access tokens agree.
- A refresh with a stored role the user no longer holds mints the full set rather
  than a narrowed one, and says so where it can be seen.
- A pool carrying non-default settings still carries them after the trigger is
  attached — asserted against a pool the test did not create, because that is the
  case the merge exists for.
- No user pool schema is amended by any of this. If a step needs a custom
  attribute, the design has regressed to the one §6 replaced.
