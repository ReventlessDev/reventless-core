# Plan: one identity provider, several platforms — scope the active-role store to the pool

**Date:** 2026-08-22
**Status:** 🚧 BUILT, NOT DEPLOY-VERIFIED. Steps 1–6 are complete. **Step 7's core
half is complete too**: both spellings are published — stack exports and `config.json`
keys — and neither old set is dropped, so nothing has to be sequenced. What remains of
step 7 is a shell change in the UI repo and two removals, all later releases.

Built and unit-tested throughout; the build is warning-free. Two things have **not**
happened, both named under "Build state": nothing has met a live pool, and the
`(sub, clientId)` pairing has not been checked against a real token.
**Scope:** `reventless/aws` (the store, the trigger, the attachment, the BYO config),
one contract statement in `reventless/core`, bindings in `rescript/pulumi-aws` and
`rescript/aws-sdk`, an operator script, and the docs that tell an operator to run it.
Step 7 additionally renames the names this platform publishes — its stack exports and
its `config.json` keys — whose shell-side half is a companion plan in the UI repo.
No change to the local platform, which has no shared minting point to contend for.
**Follows:** [active-role-narrows-the-token.md](./active-role-narrows-the-token.md) §6,
whose design this keeps. Nothing here reopens the `custom:activeRole` question — see
"What this does not change".

---

## The defect

Two platform stacks configured with the **same** BYO user pool each deploy their own
pre-token-generation trigger and their own `ActiveRoleStore`. Cognito allows a pool
exactly one `PreTokenGeneration` trigger, so the attachment is last-writer-wins: the
stack that deploys most recently owns the slot.

The winning trigger reads **its own stack's** table. The other stack's
`Platform_SetActiveRole` resolver writes **its own**. Reads and writes land in different
tables, and every role switch reports success and silently does nothing — the mutation
returns the requested role and the next token is minted from a table nobody wrote.

Observed live: two `ActiveRoleStore` tables and two trigger functions, one pair per stack,
with the pool attached to the pair whose table the serving resolver never writes.

### Why it is quiet

Each half is individually correct and individually testable. The resolver writes its
table; the trigger reads its table; the attachment does exactly what it declares. Nothing
in either stack can observe the other, so no unit test and no single-stack integration
test can see it. The failure needs two deployments and one pool to exist at all, and it
presents to a user as a control that does nothing.

## The rule this violates

The trigger slot is a property of the **pool**. The state that decides how the trigger
narrows a token is currently a property of the **stack**. A singular per-provider
mechanism cannot be driven by per-deployment state without the deployments contending for
it, and one of them losing silently.

> **State that narrows an identity must be scoped to the identity provider, not to the
> platform.**

That is provider-independent, which is why it belongs in `reventless/core` beside the
existing claim vocabulary rather than in the AWS adapter that happens to have hit it
first. Any future platform sharing one issuer across deployments meets the same defect in
a different shape — not a trigger collision, but two deployments disagreeing about a
user's active role.

**It cannot be a conformance case.** `Auth_ActiveRole.conformanceCases` are pure —
`(membership, requested) → expected` — and this invariant is about *where two deployments
keep state*, which no such function can express. It lands as a stated contract plus a
deploy-time check, and the plan says so rather than implying the suite would catch it.

## The shape: two cases, and no third

An earlier draft of this plan added a second config key naming the shared store, and left
BYO-without-that-key working on a stack-scoped table. That was incoherent. BYO means the
pool is not ours, which means we cannot know that no other platform is already on it — so
"BYO with a private store" is not a supported mode, it is the defect waiting for a second
deployment.

There are two cases and they are decided by one key:

| | Identity provider | Active-role store |
|---|---|---|
| **`identityProviderId` absent** | created and owned by this stack | created and owned by this stack, stack-scoped name |
| **`identityProviderId` set** | exists, owned outside every stack | exists, owned outside every stack, name **derived** from the provider id |

Everything the pool owns is owned on the same side of the line. Either the stack owns the
identity and everything attached to it, or it owns none of it.

### The store's name is derived, not configured

`ReventlessActiveRoleStore-<identityProviderId>` — so `eu-west-1_CQTwafSeX` gives
`ReventlessActiveRoleStore-eu-west-1_CQTwafSeX`, a legal DynamoDB name.

The earlier draft rejected derivation, for a reason that only holds under an assumption
this plan drops: *"a derived name would let two stacks both try to create the same table,
so the second deploy fails or adopts a resource it does not own."* True — while stacks
create it. In the shape above **no stack ever creates it in BYO mode**, so nobody races
anybody, and derivation is then strictly better than a key:

- two platforms on one pool **cannot** name different stores, so the defect stops being
  *detected* and becomes *unrepresentable*;
- there is no second key to set, to typo, or to drift between stacks;
- the sharing is not implicit — it is a documented convention, and a deploy that cannot
  find the table fails naming exactly what it looked for.

🚨 **One definition of the name, used by both the deploy and the script.** The derivation
lives in `Auth_ActiveRoleStore` and the provisioning script imports the compiled module
rather than re-implementing the string. A script that derived the name independently would
be one edit away from provisioning a table the deploy does not look for — which fails as
"table not found" long after the operator has moved on.

### Why the config key loses "cognito"

`platform:cognitoUserPoolId` → **`platform:identityProviderId`**, env
`REVENTLESS_IDENTITY_PROVIDER_ID`, CI secret `IDENTITY_PROVIDER_ID`. The concept — "an
identity provider this platform does not own, whose tokens it trusts" — is not
AWS-specific, and a second cloud's adapter should meet the same key rather than inventing
a parallel one.

Deliberately **not** `identityPoolId`: Cognito Identity Pools are a different AWS product
(federated identities), and the name would be actively misleading.

🚨 **Absent provider config is not an error — it is auto mode, and auto mode creates a
user pool.** So a rename that any caller fails to follow does not fail the deploy; it
silently provisions a *fresh* pool and orphans every existing user. The old key is
therefore still read, as a deprecated fallback that logs, and the workflows read
`${{ secrets.IDENTITY_PROVIDER_ID || secrets.COGNITO_USER_POOL_ID }}` — correct before the
new secret exists and after the old one is deleted, with no window in between.

The names this platform *publishes* are step 7, kept separate because they are a
contract with consumers this repo does not deploy — so they move by adding the new
names rather than by switching to them.

## Steps

### 1. `reventless/core` — state the invariant

One block in `Auth_ActiveRole.res`, next to the claim constants: narrowing state is
scoped to the identity provider, and a platform that stores it per-deployment breaks the
moment two deployments share a provider. Written as contract, not as an AWS note — the
file already carries the "what every platform must do" half of this feature.

### 2. `reventless/aws` — rename the key, derive the store, look both up

`Util_LocalConfig`-backed `identityProviderId` with the deprecated fallback above. When it
is set: the pool is looked up as today, and the store is looked up at the derived name
through a new `DynamoDb.Table.Get` binding in `rescript/pulumi-aws`. When it is absent:
both are created, exactly as today.

Either lookup failing fails the deploy. That is the "and if one of the two is not
available, the deployment should fail" half, and it costs nothing to implement because it
is what a Pulumi invoke already does.

### 3. `reventless/aws` — refuse a takeover, do not perform one

The attachment resource must `DescribeUserPool` before it writes (it already does, for
the reset-by-omission merge). Add one check on what it reads:

- no `PreTokenGeneration` trigger → attach, as today;
- our own trigger, or another deployment's active-role trigger reading the **same** store
  → attach; two platforms on one pool run the same code over the same rows, so whichever
  holds the slot serves both;
- another active-role trigger reading a **different** store → fail, naming both stores;
- **any other trigger → fail the deploy, naming what is attached.**

This is the same trade the file already makes for its denylist: given "a customer's pool
quietly loses a setting" and "the deploy fails with a parameter error", design for the
second. Today a BYO customer's own claims-enrichment trigger is replaced silently by a
deploy — on a pool the framework went to considerable lengths not to otherwise disturb.

The check reads the attached function's `ACTIVE_ROLE_TABLE` rather than matching its
name, because that is the invariant itself: two triggers agree exactly when the rows one
reads are the rows the other's resolver writes. Needs `lambda:GetFunctionConfiguration` on
the deploying principal, beside the `lambda:InvokeFunction` the pre-attach probe needs.

With step 2 in place the different-store arm should be unreachable by configuration —
it stays because it is still reachable by *version skew*, while an older platform release
is still on its stack-scoped table.

**Destroy detaches only our own function.** Where two stacks share a pool the later one
holds the slot, and a blind detach on destroy would tear out a trigger this deployment
does not own — the "every sign-in fails on a pool nothing here would fix" hazard,
arriving from the opposite direction.

### 4. `reventless/aws` — the active role is per-platform

One pool, several platforms, one row per subject means narrowing to a role in one platform
narrows the caller's session in every other platform on that pool. That is defensible —
one identity, one session — but it is not what an operator wants: a role with surfaces in
one platform and none in another leaves the second showing nothing until the caller widens
again.

Tokens are minted **per app client**, and each platform stack already creates its own.
So the narrowing can be per-platform without a second store: the row is keyed
`(sub, clientId)` rather than `sub` alone — partition key `id` (the subject), sort key
`clientId` (the app client).

Both ends must resolve the *same* client id or the row is written under one key and read
under another — the original defect in miniature. The trigger has
`callerContext.clientId`; the write door has to take it from the authorizer
(`ctx.identity.claims.aud` on an ID token, `client_id` on an access token). **Verify this
pairing against a live token before building on it** — if the two cannot be made to agree,
this step stops and the shared-role behaviour stands, rather than being papered over.

### 5. An operator script for the two resources

BYO now means provisioning two things, one of which has a name the operator must not
choose. That is a script, not a paragraph of instructions: `reventless/aws` gains one that
creates an unmanaged user pool and its active-role store, deriving the store's name from
the pool it just created, and prints the `identityProviderId` to configure.

Requirements:

- **idempotent** — re-running against an existing pool provisions only what is missing,
  because the first thing an operator does with a provisioning script is run it twice;
- **the derived name comes from the framework module**, never a copy of the string;
- **the store's key schema is the script's to own** — partition key `id` (S), sort key
  `clientId` (S), on-demand billing, point-in-time recovery on;
- **it does not attach a trigger.** The pool's trigger slot is the deploy's business, and
  a script that filled it would be the hand-run `UpdateUserPool` this whole area refuses;
- it prints what to do next rather than assuming, since the pool it made is deliberately
  not owned by any stack.

### 6. Documentation

Two places, because two audiences meet this:

- the deployment guide's per-instance-override table, where `cognitoUserPoolId` is
  documented today — renamed, with the derived store beside it and the script as the way
  to create both;
- the identity page in the app docs, where someone reading about roles and claims already
  is — what the store holds, that it belongs to the provider rather than the platform, and
  that on one provider each platform's active role is now its own.

### 7. Rename the published names — stack outputs and `config.json`

Everything this platform *publishes* still speaks Cognito, and a half-renamed surface is
worse than an unrenamed one: nobody can tell afterwards which half was deliberate. So
both go, on the same reasoning as the input key — the concept is not AWS-specific, and a
second cloud's adapter should meet the same names.

| Published as | Now | Becomes |
| --- | --- | --- |
| stack output | `cognitoUserPoolId` | `identityProviderId` |
| stack output | `cognitoUserPoolClientId` | `identityProviderClientId` |
| stack output | `cognitoUserPoolArn` | `identityProviderArn` |
| stack output | `cognitoUserPoolManaged` | `identityProviderManaged` |
| stack output | `cognitoRegion` | `identityProviderRegion` |
| `config.json` | `cognitoUserPoolId` | `identityProviderId` |
| `config.json` | `cognitoClientId` | `identityProviderClientId` |

**`authMode: "cognito"` stays.** It is a value, not a name, and what it says is true:
this deployment authenticates against Cognito. A second provider earns a second value
there rather than a rename of this one.

**`Arn` stays too, and this was asked and decided rather than overlooked.** The neutral
half of each name is our concept; the AWS half is the value's actual format, and
`identityProviderArn` reads correctly as "the ARN of the identity provider". Renaming it
to `Urn` was considered because the core `Resource` abstraction already does exactly that
— `Util_DynamoDb.toResource` passes `~urn=arn`, and `Plugin_Helpers` reads it back — so
there is real precedent for `urn` as the provider-neutral word for a resource identifier.

It loses on a collision. **This is a Pulumi codebase, and `urn` already means the Pulumi
URN** (`urn:pulumi:stack::project::type::name`) that every resource carries. A published
output called `identityProviderUrn` would be read as the pool resource's Pulumi URN,
which it is not — and a consumer acting on that reads the wrong identifier with nothing
to warn them. The internal `Resource.urn` survives the same objection only because
nothing parses it; a published contract invites parsing, and an ARN is not a URN in the
RFC 8141 sense either. A second cloud's adapter should publish `identityProviderResourceId`
— a different name because it is a different kind of value.

**`cognitoUserPoolArn` has no readers.** It is exported and nothing in this repo consumes
it through `StackReference`. So it needs no transition at all, and it is worth asking
whether it should be renamed or simply deleted before doing either.

#### The two surfaces fail differently, and that decides the method

**Stack outputs fail loudly.** `Platform.res` reads them through `StackReference` and
already errors by name when an export is missing, so a mismatch stops a plugin deploy
with a sentence. Staged across releases:

1. Export **both** names — **done**. A plugin stack pinned to an older
   `reventless-aws` keeps resolving.
2. Switch the readers to prefer the new name and fall back to the old, the fallback's
   error message naming both — **done**. Both levels fall back: the direct output and
   the ESM-nested `default.<key>` form.
3. Drop the old exports, once no pinned consumer reads them — **not done**, a later
   release.

**`config.json` fails silently, and one of its two keys takes authentication with it.**

`cognitoClientId` is what the shell's auth provider actually switches on — silent
refresh, login, and token refresh all branch on it being present. It is read into an
`option`, so a key the shell cannot find is not an error: it is `None`, and every one of
those branches quietly falls through. Renaming it out from under a deployed bundle is a
**total auth outage that reports nothing.**

`cognitoUserPoolId` is the opposite and the discovery worth recording: it is threaded
from `config.json` through the shell's config record into the auth provider, which then
**explicitly discards it** — the password flow needs only the client id, and the
parameter is reserved for SRP and hosted-UI flows that do not exist yet. Renaming it
breaks nothing today.

The two sitting side by side in one computed array is the trap. A sweep over `cognito*`
in `Platform.res` takes both, only one of them tells you, and the one that does not tell
you is the one that is fine. **Rename by name, never by pattern.**

#### Write both keys rather than sequencing a flag day

The obvious plan — teach the shell the new key, release it, pin it, then switch — makes
correctness depend on a release ordering that cannot be observed: the shell reads
`config.json` at runtime and CloudFront serves the previous bundle until someone
invalidates it, so there is a window where the served bundle and the served config
disagree and the only symptom is that nobody can log in.

Don't sequence it. **Emit both spellings** in `config.json` for a transition. It is a
JSON blob written at deploy time; two extra keys cost nothing, and any bundle — old,
new, or stale in a CDN — finds one it understands. The ordering dependency disappears
instead of being managed.

Then, in order and each independently safe:

1. this repo writes both keys — **done**;
2. the shell prefers the new key, falls back to the old — a UI-repo change, released and
   tagged, then pinned here from the tag;
3. this repo stops writing the old keys;
4. the shell drops the fallback.

Only step 3 needs the pin from step 2 to be in place, and that is checkable by reading
`platform-aws/package.json` rather than by hoping about cache state.

The shell half is a companion plan in the UI repo — see [Cross-repo plans]; nothing here
should try to describe the shell's own release.

**Also to update:** `Util_ShellConfigTest`, the computed-key collision note in
`ui-configuration.md` (two new computed keys can newly collide with a `shellConfig` key),
the `config.json` key list in `ui-fragments-deployment.md`, and the
`cognitoUserPoolManaged: false` reference in
[active-role-narrows-the-token.md](./active-role-narrows-the-token.md).

## What this does not change

- **`custom:activeRole` stays rejected.** §6 settled it: a custom attribute is a one-way
  door on a customer's pool, and that judgement holds whether or not one pool serves one
  platform or several. Deriving the store from the pool achieves the same sharing property
  without amending the pool's schema.
- **The narrowing policy.** `decide`'s three readings — unchanged, narrow, stale — and
  every conformance case are untouched. Steps 2–3 move where the desired role is kept;
  step 4 changes whose question it answers, and neither changes what narrowing means.
- **The local platform.** It mints its own tokens and re-mints on switch, so it has no
  shared slot and no store to scope.
- **`V1_0`.** Still deliberate, still for the reason §6 gives.
- **`authMode: "cognito"`.** A value naming which provider authenticates this
  deployment, and it is true. A second provider earns a second value.

## Verification

- Two stacks configured with one provider id: a switch performed against either stack's
  resolver is honoured by the next token, whichever stack's trigger holds the slot.
- The same two stacks: a switch in one does **not** narrow the caller's session in the
  other — the per-app-client keying, asserted from decoded tokens on both sides rather
  than from either console.
- A pool carrying a foreign `PreTokenGeneration` trigger fails the deploy with that
  trigger named, and the pool is left exactly as it was — the assertion is on the pool
  after the failed deploy, not only on the error.
- `identityProviderId` set to a pool with no store at the derived name fails the deploy
  naming the table it looked for.
- Auto mode is byte-identical to today: no new config, stack-scoped table, attachment as
  an ordinary property.
- The old config key still resolves, and says it is deprecated.
- After step 7.1, `pulumi stack output` lists both spellings and they carry equal values —
  asserted against a deployed stack, since a duplicated export is exactly the kind of
  thing that compiles and then exports one of them.
- After step 7.2, a plugin stack deploys against a platform exporting **only** the old
  names, and against one exporting only the new — the fallback is the whole point of the
  step and neither direction is exercised by the ordinary case.
- Running the script twice leaves one pool and one store.
- The reset-by-omission test still passes — a pool with non-default settings still has
  them after an attach.

## Risk

**The rename is the dangerous half, and not for the obvious reason.** A missed caller does
not fail — it falls through to auto mode and provisions a new user pool, which looks like
a successful deploy and orphans every existing user. The deprecated fallback and the
`||` in the workflows exist for exactly that, and neither should be removed until the new
secret is confirmed in place.

**Step 3 turns a currently-succeeding deploy into a failing one** for any deployment that
has already had its pool's trigger taken over. Intended, and also breaking: those
deployments must move to the derived store or stop sharing the pool. Worth a release note,
and worth failing rather than continuing to serve a role switch that cannot work.

**Step 7 can take authentication down without reporting anything.** `cognitoClientId` is
read from `config.json` into an `option`, so a bundle that cannot find its key does not
error — it gets `None`, and login, silent refresh and token refresh all quietly fall
through. Its neighbour `cognitoUserPoolId` is discarded by the shell today and renames
harmlessly, which is precisely what makes a `cognito*` sweep dangerous: the safe one
gives no warning and the unsafe one gives no error. Emitting both spellings through the
transition is what removes the hazard; renaming by pattern is what creates it.

**Step 4 relocates every existing row.** A store keyed `(sub, clientId)` does not answer
reads keyed `sub` alone, so every caller's stored preference reads as absent once and they
mint full membership until they choose again. That is the safe direction to fail and it
needs no migration — but it must be said out loud, because the alternative reading is that
role switching broke for everyone at once.

## Build state

| Step | Where |
| --- | --- |
| 1. The invariant, stated | `reventless/core/src/adapter/Auth/Auth_ActiveRole.res` |
| 2. Rename, derivation, both looked up | `Platform_Stack.res`, `Auth_ActiveRoleStore{,_Schema}.res`, `rescript/pulumi-aws` `DynamoDb.Table.Get` |
| 3. Refuse a takeover | `Auth_ActiveRolePoolAttachment.res` (`classifySlot` / `refusalFor` / `attachedTriggerArn`, destroy guard) |
| 4. Per-platform active role | `Auth_ActiveRoleStore_Schema.res` (the pair key), `Auth_ActiveRoleStore{,_Ops}.res`, `Auth_ActiveRoleTrigger_Ops.res` |
| 5. Operator script | `reventless/aws/scripts/ProvisionIdentity.res`, `pnpm run provision:identity` |
| 6. Docs | deployment guide (+ BYO section), identity page, deploy tutorial, custom-domain, ui-fragments |
| Workflows | all three core deploy workflows pass both secret spellings |
| Tests | 98 across four suites (was 65) |
| 7. Published names renamed | **core half done** — both spellings exported and both `config.json` keys written; `Util_ShellConfig.identityFields` + 4 tests. Dropping the old names and the shell's own change are later releases |

The store's name and key schema live in **one** module, `Auth_ActiveRoleStore_Schema`,
which is Pulumi-free and SDK-free (`No side effect` footer) so both Lambda bundles and
the CLI can import it without dragging a deploy-time dependency into a runtime graph.

### What has not happened

- **Nothing has met a live pool.** Every check here is against pure functions —
  `chooseStore`, `derivedStoreName`, `keySchemaRefusal`, `classifySlot`, `refusalFor` —
  which is deliberate, and is also the whole of the evidence. No `UpdateUserPool`, no
  `CreateTable`, no refused deploy has actually been observed.
- **The `(sub, clientId)` pairing is unverified against a real token.** Step 4 said to
  check it first; it could not be, so the write door **refuses** rather than substituting
  anything when it cannot read the app client, and the trigger falls through to full
  membership when Cognito hands it none. Both failures are loud or safe rather than
  silent — but "the resolver's `aud`/`client_id` equals the trigger's
  `callerContext.clientId`" is still an assumption, and it is the assumption the feature
  rests on. Decode both sides on the first deploy before trusting a green run.
- **The old config key is still read.** Removing it is a separate act, after the new
  secret is confirmed everywhere. See Risk.
- **The estate on the shared pool needs its store created** before it deploys against
  this, with `provision:identity --provider-id`. Its two existing tables are superseded.
