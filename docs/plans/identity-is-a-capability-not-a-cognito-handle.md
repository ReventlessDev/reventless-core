# Plan: identity is a capability, not a Cognito handle

**Date:** 2026-09-10
**Status:** Step 0 ✅ **measured 2026-09-10 — the answer is yes.** Changing the login identifier
replaces the pool and empties it, which made it the workstream's most urgent item; **Step 5a ✅ shipped
the same day** and it is no longer a countdown. Step 5b turned out to be free and is not urgent, and
5c is named-and-not-built. **Steps 1 and 4 ✅ shipped 2026-09-10** — the declaration, the plugin door,
the refusing arm and the deploy gate, with `setActiveRole` decided *out* of the capability. **Step 2 was
measured 2026-09-10 and its premise was false:** the log does not have a clean slate — `Identity.userId`
*is* the Cognito `sub` on AWS, and three shipped paths already persist it, one of them into domain
payloads. Step 2 is re-cut around that; it turns out to be one seam wide, additive, and **not** urgent.
**Step 3 was investigated 2026-09-10 and its stated gap was wrong too** — the auth-posture vocabulary
already exists as `Authorization.AllowAnonymous`, and AWS silently enforces it as *authenticated only*.
Step 3 is re-cut into three pieces, and **the first — refusing to compile `AllowAnonymous` into a
directive that contradicts it — ✅ shipped 2026-09-10**, as did **Step 5b** (862 aws tests green, both
verified by deletion). **Steps 3b (an API-key auth provider, its missing Pulumi binding, and key
rotation), 3c (the door) and 2 are what remain**, and 3b is the one gating an anonymous door on AWS.
**Repos:** `reventless-core` only.

**Goal.** Put the *administrative* half of identity — making, grouping and unmaking principals —
behind a capability, so the provider is replaceable and no provider-shaped id is ever written into an
event.

**Non-goal.** Authentication. Token issuance, JWT verification and session handling already live in
`Auth_Adapter.Provider`, which is a different and correctly-shaped seam. Two seams over one provider is
not duplication — they are read at different times, exactly as `Capabilities.t` and `CapabilityNeed.t`
are.

**Build this whether or not anything is built on top of it.** It is what makes the identity provider
replaceable, and it is the piece that decides whether a log full of provider ids is ever written.

---

## The gap

**The vocabulary is already neutral; the capability is missing entirely.** `Platform_Stack.res` renamed
its config key from `cognitoUserPoolId` to `identityProviderId` and publishes
`identityProviderId` / `identityProviderClientId` / `identityProviderArn` / `identityProviderRegion` /
`identityProviderManaged`. The rename kept a deprecation path that still reads the old spelling,
because an unread key silently means *auto mode* and would mint a fresh pool, orphaning every account.

What did not exist, as of filing: no arm in the platform capability variant, no member on
`Capabilities.t` (which carried `geocode` and `messaging` and nothing else), no constructor in
`CapabilityNeed.t` (two arms — `Geocoding`, `Messaging`), no refusing arm in `Capabilities.none`, and
therefore **no deploy gate**. ✅ **All five landed 2026-09-10** (Steps 1 and 4). What still does not
exist is a *backend* behind any of them — which is why the gate refuses.

**Three shipped facts make self-service impossible today, and each needs a different answer.**

1. `Platform_Stack.res:190` provisions its auto pool with `allowAdminCreateUserOnly: true`. A
   deployment that took the default cannot self-register anybody. That default is right for a
   hand-created-accounts model, but it means self-signup is a **provisioning** change, not a code-only
   feature — so it must become a setting on the capability rather than a hard-coded record field.
2. `Util_Cognito_Runtime.signUpIfMissing` catches everything into a log line; its comment says
   *"Intentionally silent on failure: user may already exist (idempotent sign-up)"*. Right for a
   seeding helper, wrong for a registration path, where "this address is already a principal" is
   precisely the decision the flow turns on. It is reusable as a reference, not as an implementation.
3. `UserStore.res` hydrates `LocalAuth.Login.store` from `.reventless/users.yaml` at start and nothing
   writes back, so the local platform has no way to create a principal at all.

## Step 0 — measured 2026-09-10: **yes, and Step 5 is now the top of the workstream**

`Platform_Stack.res:207` provisions the pool with `usernameAttributes: ["email"]`, hard-coded. The
claim this plan was built on is that the attribute is fixed at pool creation, so changing it **replaces
the pool and destroys every account in it**. That claim was asserted from outside the repo. It is now
measured **inside** it, and it holds.

**The measurement, and why it beats the `pulumi preview` this step originally asked for.** The AWS API
itself settles it, and its shapes ship in `node_modules`
(`@aws-sdk/client-cognito-identity-provider/dist-types/models`):

| | `CreateUserPoolRequest` | `UpdateUserPoolRequest` |
|---|---|---|
| `UsernameAttributes` | ✅ present | ❌ **absent** |
| `AliasAttributes` | ✅ present | ❌ absent |
| `UsernameConfiguration` | ✅ present | ❌ absent |
| `AdminCreateUserConfig` | ✅ present | ✅ **present** |
| `AutoVerifiedAttributes` | ✅ present | ✅ present |

`UpdateUserPool` has twenty-one members and the login identifier is not among them. There is no API
call that changes it, so *no* provider can change it in place — this is a property of Cognito, not of
Pulumi, Terraform or CloudFormation, and a `pulumi preview` would only have re-observed one bridge's
reaction to it. Replacement is the only path, and a replaced pool is an empty pool.

**The reading that changes the plan: the two settings Step 5 moves are not the same kind of thing.**
`AdminCreateUserConfig` *is* updatable in place, so flipping `allowAdminCreateUserOnly` off is an
ordinary in-place update and self-service sign-up can be turned on at any time, on a pool full of
accounts, for free. The login identifier cannot. Step 5 currently presents the pair as one decision;
they are a first-deploy-or-never decision and a free one, and only the first is urgent.

*Consequence, per the orchestrator's stated gate:* **Step 5's login-identifier half is the
highest-priority item in the workstream.** Every account created before it lands is an account a later
phone-sign-in decision destroys. Its self-service half is not urgent at all and can follow the rest of
the capability.

**A by-product worth not rediscovering: do not ask the Pulumi schema this kind of question.**
`pulumi package get-schema aws@7.19.0` reports `replaceOnChanges: false` for `usernameAttributes` — and
for everything else. **Zero** resources in the bridged AWS provider carry `replaceOnChanges: true` on
any input, because a bridged provider decides `ForceNew` inside its own `Diff` at runtime and never
populates that schema field. A `false` there is an absence of information, not an answer, and reading it
as one would have produced a confident wrong result on this exact question.

## Step 1 — the declaration ✅ **done 2026-09-10**

A third arm beside the two that exist, with no payload, for the same reason `Geocoding` has none: one
identity provider per deployment is a real answer. A deployment wanting two pools (staff and customer)
is the `{alternatives, min}` question `Messaging` already answers by publishing channels — not a reason
to parameterise now.

`CapabilityNeed.t` gains `IdentityProvider` with its `toString` / `fromString` spellings, matching the
existing arms' discipline that a persisted structure holds strings so an older reader still decodes a
newer plugin's need.

**Built, and the compiler found three more consumers than this step named.** The arm is nominal, so
exhaustiveness located every place that renders a capability rather than leaving them to a grep:

| Site | What it needed |
|---|---|
| `CapabilityNeed.t` | the arm, `toString`, `fromString` |
| `CapabilityManifest.kind` | its own parallel variant, plus the `need → kind` map |
| `PlatformCodegen.renderEntry` | the line the generator prints into a platform's capability list |
| `Platform.capability` (infra) | the arm that generated line has to land on |
| `Platform.res` (aws) ×2 | the store-dedup filter, and the deploy gate's per-capability advice |

That last one is the point of the whole step: the gate now has an `IdentityProvider` refusal, and it
says what is true — *no platform has a backend yet, and no configuration change will produce one*
— rather than sending a deployer to look for a setting that does not exist.

## Step 2 — the persisted reference: **measured 2026-09-10, and the premise was false**

The rule stands and is still the load-bearing line: **a domain event must never persist a Cognito
`sub`, a pool id, or any provider-shaped user id**, because a reference written into a million events is
permanent and a log full of one provider's ids cannot be migrated — which would make the replaceability
this capability exists for a fiction.

What was wrong is the *state* this step claimed. It said the layout is still free because nothing has
written a principal yet. Nothing has written one **through this capability** — but the provider-shaped
id has been reaching the log by another path since long before this plan was filed, and it is in domain
**payloads**, not only in metadata.

### The measurement

`Auth_Cognito._identityFromClaims` sets `Identity.userId` from the token's `sub` (`Auth_Cognito.res:63`),
and `fromAppSyncIdentity` sets it from the resolver's already-validated `identity.sub` (line 157). On
AWS, `Identity.userId` **is** the Cognito `sub`. Three shipped paths then persist it:

| Site | What it writes | Reach |
|---|---|---|
| `CommandGenerator_Callback.makeGenerateCommand` | `meta.user` on every command, into `StoredEvent.meta` — which the DynamoDB adapters flatten to top-level attributes so meta keys stay GSI-projectable | every event, every deployment, both platforms |
| `CommandGenerator_Callback.stampOwnerFields` | overwrites every `@owner`-marked **command field** with `userId`, so it lands in the event *payload* rather than the envelope | `PlaceOrder`'s `customerId`, `Subscribe`/`Unsubscribe`'s `recipientId`, and every state-view row derived from them |
| `Auth_ActiveRoleStore_Ops` | the row key, `ctx.identity.sub` by its own comment (line 14) | every active-role row |

`Identity.res:8` states the intent precisely — *"NOT persisted in events — only `userId` is stored as
`meta.user`"* — and the second clause is the leak that the first clause reads as denying. The
`Message.res:250` parent-to-child propagation then carries `user` down the whole causal chain, so a
derived command inherits it too.

**Independent corroboration, from the other end:** the known defect where demo owners seeded under
`local-*` ids leave every owner-scoped view empty on AWS is this same fact observed as a bug. The same
person has a different id on each platform *because the id is the provider's*.

So the honest statement is not "the layout is still free." It is: **the decision was already taken by
default, on every deployment that has ever run, and Step 2's real subject is what unmaking it costs.**

### What the measurement makes cheap — and it is the reason to keep going

**The leak is one seam wide, not three.** Every one of those three sites reads `Identity.userId` and is
already provider-agnostic; not one of them names Cognito. The provider id becomes a domain id in exactly
two functions, both in `Auth_Cognito.res`. Change what those two produce and all three sites become
domain-shaped with no edit at all. That is only visible once the sites are enumerated, and it is the
difference between a one-file change and a sweep across the command pipeline.

### The direction split — and only one direction needs a store

**Measured, not assumed:** `ListUsers`' `Filter` accepts nine standard attributes plus `sub`, and the
API's own documentation closes the list with *"Custom attributes aren't searchable."* So the tempting
no-store design — put the domain id on the principal as a custom attribute and ask the provider — answers
the hot direction and **cannot** answer the cold one. The store is genuinely required, and now for a
stated reason rather than by assumption.

| Direction | When it is needed | Answer |
|---|---|---|
| provider → domain | every authenticated request | a claim carried in the token; **no store read on the request path** |
| domain → provider | admin ops only: group, ungroup, delete | the capability's own store — unavoidable, per the measurement above |

That split is what keeps the store off the hot path, which is what makes it affordable at all.

### Existing accounts: additive, and **not** a countdown

An account created before this lands carries no domain-id claim. The fallback for an absent claim must
therefore be **`userId = sub`** — which reproduces today's value exactly, so every order already holding
a `sub` as its `customerId` keeps matching its owner and no state view is rebuilt. New accounts get a
minted domain id in a shape that cannot be mistaken for a UUID. A mixed pool is fine: both are opaque
strings and neither collides.

**And unlike 5a, this can be done to the pool that already exists.** `CreateUserPoolRequest` carries
`Schema` and `UpdateUserPoolRequest` does not — the same shape as the login identifier, and the reason
to check rather than infer — but **`AddCustomAttributes` is its own API operation**, so a custom
attribute can be added to a live pool. It is one-way, since an attribute can never be removed or
renamed, which makes it a decision worth making deliberately. It is not a first-deploy-or-never one.
**Step 2 is 5b-shaped, not 5a-shaped: it is not urgent, and it does not restart the countdown 5a
closed.**

### What is still open, and the recommendation

Which store, and who provisions it. The recommendation is the shape 5b already argued for the pool
settings: **the capability owns the mapping, the platform provisions the storage** — a DynamoDB table
beside `Auth_ActiveRoleStore` with a derived name on AWS, and the existing `.reventless/users.yaml` on
local, which Step 3's `createPrincipal` has to learn to write to anyway. Both are the identity-adjacent
state that already exists on each platform, and neither is the event log.

Still unanswered, and it should not be closed by omission: **what happens when the store disagrees with
the provider** — a principal deleted out-of-band leaves a mapping row pointing at nothing. That is the
one part of this step that has no precedent to copy.

**Nothing here has been built.** This step remains a decision, and the decision is now being taken
against measured facts rather than an assumed clean slate.

## Step 3 — the client door: **the gap is real, and it is not the one this step named**

The door's *shape* is unchanged: a GraphQL field on the platform API rather than a bare endpoint,
re-registered by the local platform over its own backend — the way portability is demonstrated rather
than asserted, as `Upload_Presign` already does for the object store. And the requirement is unchanged:
**these doors must be callable unauthenticated**, because being authenticated is what the caller is
trying to become.

Everything this step said about *where that gets declared* was wrong, in both directions, and the
correction makes the step larger rather than smaller.

### The vocabulary is not missing — it exists, and it is already wrong on one platform

This step asked whether to extend the manifest, on the grounds that it "carries
`ownedComponents[].clientDoor` and nothing about who may knock." **There is no `clientDoor` field and no
`ownedComponents` field**; `CapabilityManifest.entry` is `{kind, key, declaredBy}` and the manifest has
no notion of a door at all. "Door" is this repo's prose, not its schema.

The declaration it was reaching for exists somewhere else and has all along:
`Authorization.permission` publishes **`AllowAnonymous`** beside `AllowAuthenticated`, `AllowGroups`
and `DenyAll`, and it is `@schema`'d, so it already persists and already travels.

That answers the delegated question — *is an unauthenticated door's auth posture a trait declaration or
a framework concept?* — without waiting for a second case: **it is a framework concept, and the
framework already has it.** Nothing should be added to the manifest.

**What is broken is the AWS half of its implementation:**

| Platform | How `AllowAnonymous` is enforced | What it actually means |
|---|---|---|
| local | `Authorization.isAllowed(rule, identity)`, called in the resolver | anonymous callers are admitted — the rule is honoured |
| AWS (mutations) | an SDL directive and nothing else; `AllowAuthenticated \| AllowAnonymous => None` collapses both to `cognitoOpenDirective` | `@aws_cognito_user_pools` — **any *authenticated* Cognito caller**. Anonymous is refused |

There is no runtime `isAllowed` on the AppSync mutation path to catch it: the only `isAllowed` call in
`reventless/aws/src` is on the Postgres *query* resolver. A registration mutation is a mutation, which
is exactly the path where the directive is the whole enforcement.

So a spec declaring `AllowAnonymous` today **deploys green, passes `assertGateable`, works on local, and
is unreachable on AWS by precisely the callers it exists for.** It fails closed, which is the safe
direction and is why nobody has hit it — and it is fatal for this step specifically, because the
registration door is the one field in the system whose whole purpose is to admit someone with no
identity yet.

This is the second silent authorization divergence in this adapter. The first — `@aws_auth` ignored on a
multi-auth API, group gates failing *open*, recorded in `appsync-group-authorization-unenforced.md` — is
what motivated `assertGateable`, whose stated job is to make "carries no directive" detectable rather
than silently permissive. `AllowAnonymous` slips past it by carrying a directive that is well-formed and
means something else.

### AppSync cannot express "no auth" at all, and that is the real cost

Measured in the binding: `AppSync.GraphQLApi.authenticationType` has four arms — `API_KEY`, `AWS_IAM`,
`AMAZON_COGNITO_USER_POOLS`, `OPENID_CONNECT`. **There is no anonymous arm**, and the adapter provisions
Cognito primary with AWS_IAM additional, unconditionally. An unauthenticated field therefore needs
`API_KEY` added as a *third* auth provider — an API-level change touching every field's directive story,
not a per-field decoration — and **there is no `AppSync_ApiKey` binding in `rescript/pulumi-aws`** to
declare the key with.

An API key is also a shared secret shipped to the browser, and (asserted from outside this repo, worth
confirming before relying on it) one that expires, with a maximum lifetime around a year — so a public
registration door authenticated this way **breaks on a timer** unless something rotates it. That is an
operational commitment, not a directive.

### The precedent this step cites points the other way on posture

`Upload_Presign` is the right precedent for the door's *shape* and a counter-precedent for its *auth*:
its own header records that it has "no Function URL and no anonymous surface," and that the anonymous
Function URL it used to carry, along with an unverified `decodeJwtSub`, was deliberately removed. The
one place this system built an anonymous surface, it took it out again. That does not forbid this step —
registration genuinely needs one — but it means an anonymous door is a departure with history, and the
reasons that removal was right are the ones this door has to answer.

### What this makes Step 3

Three pieces, and only the first is small:

1. **Stop the silent divergence** — ✅ **built 2026-09-10, see below.**
2. **The API-key auth provider and its binding**, if the anonymous door is to exist on AWS at all —
   plus whatever rotates the key.
3. **The door itself**, on both platforms, over a backend Step 2 has not decided the storage for.

Only (1) was affordable, it was worth doing on its own, and it was worth doing **whether or not this
capability is ever finished** — a live correctness gap in a shipped authorization rule is not this
workstream's to hoard.

### Step 3a — the divergence is closed ✅ **2026-09-10**

`AllowAnonymous` no longer compiles into the directive that contradicts it. The deploy is refused
instead, which is 5a's rule for an unrecognised login identifier applied to the same class of mistake:
a silent contradiction of the source is worse than a stopped deploy, because only one of the two is
discoverable.

What changed, in `AppSync_Adapter`:

- **`_permissionToCognitoGroups` became `_permissionToGate`, returning a real variant** —
  `Groups(array<string>) | AnyAuthenticated | Anonymous` — instead of `option<array<string>>`. The
  option form is *why* the bug existed: it had no way to hold `AllowAuthenticated` and `AllowAnonymous`
  apart, so both landed on `None`. With the arms distinct, re-collapsing them is a deliberate edit that
  fails a test rather than a shrug that types fine.
- **Both entry kinds collect offending fields and refuse once**, so one deploy reports every field
  rather than turning a batch of them into as many failed deploys. A query reports **both** derived
  field names, because the spec declares one permission and the generator emits two fields from it —
  naming one would send the author hunting a declaration that does not exist.
- The refusal names the fields, says what the emitted schema would have meant, says that the local
  platform *does* honour the rule so a locally-green spec can still be undeployable here, and points at
  the API-key work that piece 2 would need.

*Evidence:* `reventless/aws` builds warning-free; **851 tests in 73 suites green** (up 5). The five new
tests were **verified by deletion**: restoring the single collapsed arm
(`AllowAuthenticated | AllowAnonymous => AnyAuthenticated`) turns exactly those five red and nothing
else. One of them exists specifically to outlive the others — it asserts that the two permissions do
*not* behave alike, because a test that only checks "it throws" would still pass if a later edit
re-collapsed the arms and dropped the refusal together.

*Blast radius, checked rather than assumed:* **no example, trait or shipped spec declares
`AllowAnonymous`.** The only declarations are three DynamoDB-Local integration fixtures under
`reventless/aws/tests/integration/`, and they never reach the SDL path — they exercise the aggregate
runtime, where the rule is honoured. Nothing that deploys today starts failing.

**What this does *not* do:** it does not make an anonymous door possible on AWS. It converts a silent
wrong answer into a loud refusal, which is the whole of its claim. Pieces 2 and 3 are untouched, and
until piece 2 exists the registration door cannot be deployed to AWS at all — which is now a fact the
deploy states rather than one a stranger discovers.

## Step 4 — the plugin door

```rescript
type principal = {providerId: string}      // opaque; the provider's own handle

type identityProvider = {
  createPrincipal: (
    ~contact: Messaging.recipient,
    ~credential: credential,
    ~groups: array<string>,
  ) => promise<result<principal, failure>>,
  addToGroup: (~principal: principal, ~group: string) => promise<result<unit, failure>>,
  removeFromGroup: (~principal: principal, ~group: string) => promise<result<unit, failure>>,
  deletePrincipal: (~principal: principal) => promise<result<unit, failure>>,
  /** Which operations this deployment's provider actually supports — the
      runtime-introspectable provisioned set, published rather than inferred. */
  operations: array<operation>,
}

type failure =
  | Conflict            // the contact is already a principal — a domain decision
  | Unavailable(string) // retryable; the provider is down, the domain fact stands
  | Refused(string)     // permanently rejected (policy, password rules)
```

**Three failure arms rather than two, and the split is the one geocoding taught: a provider outage is
not a verdict.** `Unavailable` on `createPrincipal` must retry, because the domain has already recorded
that the address was verified and the person is entitled to an account. `Refused` is permanent and must
surface. Collapsing them either loses accounts to a transient blip or retries forever against a
password policy. `Conflict` is a *modelled answer*, not an exception — which is exactly what
`signUpIfMissing` throws away today.

`Capabilities.none` gets a refusing arm answering `Unavailable` on every operation with
`operations: []`, so a deployment with no identity provider degrades the way the existing arms already
do rather than failing in an unmodelled way.

**`operations` is why this is a published set rather than a fixed one.** `setActiveRole` is the case
that decides its shape: Cognito implements active-role narrowing with a pre-token-generation trigger
and a DynamoDB table; a provider with no trigger implements it differently or not at all. If it is a
capability operation, `operations` must be able to say a provider lacks it and callers must degrade.
**Decide this in Step 4, not when someone tries the second provider.**

### Built 2026-09-10 — what shipped, and the one decision it settles

`IdentityProvider.res` in `spec`, plus the `identityProvider` member on `Capabilities.t` and its
refusing arm on `Capabilities.none`. Both platforms — local and the AWS automation entry point — pass
that refusing arm, so the seam exists everywhere and lies nowhere.

**Decision: `setActiveRole` is *not* a capability operation.** The delegated instruction was "if yes,
`operations` must be able to say a provider lacks it". The answer is no, and the plan's own non-goal is
why: narrowing a caller's claims happens when a **token is minted** — on Cognito, inside the
pre-token-generation trigger — and token issuance is `Auth_Adapter.Provider`'s, explicitly excluded at
the top of this file. Admitting it here would grow the surface along an axis unrelated to whether the
principal store is replaceable, which is the only thing this type exists to protect. `operations`
therefore publishes four arms — `CreatePrincipal`, `AddToGroup`, `RemoveFromGroup`, `DeletePrincipal` —
and keeps earning its place on providers that genuinely differ: a read-only directory bind creates
nothing, and a provider with no group model cannot be asked about groups. A test asserts the four, so
adding a fifth is a deliberate act rather than a drift.

Two shapes changed from the sketch above, both to make a wrong call harder to write:

- **`credential` is a variant, not a `string`.** `Password(string) | NoCredential`. Verify-then-create
  captures the password on the proof step, and a passwordless or federated enrolment has no secret at
  all — a bare string would have to be given a meaningless value at exactly the call site that matters.
- **`make` is the constructor, not a record literal**, so a provider cannot publish an operation and
  omit the function that performs it. `supports(~operation)` is the read side.

*Evidence:* every package builds warning-free; **3,374 tests across 286 suites green** (spec 626,
core 1,150, local 741, aws 846, infra 12). Two of those are new and assert the gate directly — a plugin
declaring `IdentityProvider` is reported unmet while nothing provisions one, and `Capabilities.none`
answers `Unavailable` rather than `Refused` on every operation, because a caller that got this far has
already proven their address and `Refused` would strand them.

**What is deliberately still missing:** Steps 2 and 3. There is no backend on either platform, and that
is why the gate refuses rather than warns. This paragraph originally added that nothing writes a
principal yet, so Step 2's decision was still free — **Step 2's own measurement has since withdrawn
that**, and the withdrawal is worth leaving visible: the id was reaching the log by a path this step
never looked at, which is what an unexamined "nothing has happened yet" is usually hiding.

## Step 5 — the deploy-time handle, which is already leaking

```rescript
type cognitoUserPool = {
  poolId, clientId, poolArn,        // Cognito nouns in a neutral-ish layer
  managed: bool,
  activeRoleTable: Auth_ActiveRoleStore.storeTable,   // a DynamoDB table
}
```

This is the `bucketArn` problem one capability later, with an extra turn: `activeRoleTable` is read by
a Cognito **pre-token-generation trigger**, the mechanism that narrows `cognito:groups` to the role a
caller chose to act as. That is real, shipped, working infrastructure welded to one provider, and an
honest capability has to say what it means elsewhere.

Two settings move off the hard-coded literals. Step 0 established that they are not the same kind of
thing, so they are now two steps rather than one.

### Step 5a — the login identifier ✅ **done 2026-09-10**

`Auth_LoginIdentifier` — a three-arm variant (`Email` / `Phone` / `EmailOrPhone`), free of Pulumi and of
the AWS SDK so its two consumers can share it: the auto pool in `Platform_Stack.res` and the BYO pool in
`scripts/ProvisionIdentity.res`, which were hard-coding `["email"]` in two places that could drift.

- `platform:loginIdentifier` config, through the same env / sidecar / stack-config precedence as
  `identityProviderId`. **Absent means `email`**, so every existing stack redeploys byte-unchanged.
- **An unrecognised spelling fails the deploy rather than defaulting.** This is the whole point: a typo
  that fell back to `email` would create a pool signing in on an attribute nobody can change, and the
  correction is a rebuild that re-registers every account. `"Email"` is refused too — Cognito's
  attribute names are lowercase and two accepted spellings for one pool is a second way to be wrong.
- `--login-identifier` on the provisioning script, same variant, same refusal.
- A new stack output `identityProviderLoginIdentifier`, because the value a pool was *born* with has to
  be readable somewhere other than a source file that has since moved on. `unknown` for a BYO pool:
  `getUserPool`'s result type carries no `usernameAttributes`, so reporting one would be a guess.

*Evidence:* `reventless/aws` builds warning-free; 846 tests in 73 suites green, 22 of them across
`Auth_LoginIdentifierTest` and `ProvisionIdentityTest`.

### Step 5b — self-service sign-up ✅ **done 2026-09-10**

`allowAdminCreateUserOnly: true` was hard-coded. `AdminCreateUserConfig` **is** in
`UpdateUserPoolRequest`, so as an API fact this is an in-place update on a live pool: free, reversible,
and correctable at any point. It moves onto the capability with Steps 1–4 rather than ahead of them.

**But "in-place" answers the API question, not the ownership one, and the two pool paths differ.** The
auto pool is the stack's, so this really is one declared property changing. **The BYO pool is not**: on
that branch the stack holds no pool handle at all — it declares a `UserPoolClient`, looks the pool up
read-only, and reaches the pool itself only through `Auth_ActiveRolePoolAttachment`, a resource that
exists precisely because *"we hold no handle to set `lambdaConfig` on, and Cognito offers no separate
attachment resource."* `adminCreateUserConfig` is in exactly the same position.

So 5b is two halves with different owners, and only the first is the stack's work:

| Pool | Where the flip lives | Cost |
|---|---|---|
| Auto (`HostUiPool`) | a declared property, driven by the capability setting | one property |
| BYO / supplied | `scripts/ProvisionIdentity.res`, beside 5a's `--login-identifier` | a flag on a script that already exists |

Putting the BYO half in the provisioning script rather than in a second merge-and-send-back resource is
the recommendation: the script already provisions the pool no stack owns and already carries the other
first-deploy identity choice, so the two settings that describe *the pool itself* stay in one place.
A second attachment resource would be the alternative, and it would be a dynamic provider's worth of
machinery to avoid a flag.

🚨 **On a shared pool the flip is pool-wide, not stack-wide.** Every stack pointed at that pool gets
self-service the moment one deployment turns it on, because the setting belongs to the pool and the
pool has one of it. That is the same shape as the single pre-token-trigger slot the attachment resource
already guards, and it is a blast-radius fact rather than a cost: a deployment that must never
self-register cannot rely on its own stack config to prevent it, and should not share a pool with one
that does.

#### Built 2026-09-10 — both halves, as planned above

`Auth_SignUpMode` — a two-arm variant (`AdminOnly` / `SelfService`), free of Pulumi and of the AWS SDK
so the auto pool and the provisioning script share one definition, exactly as `Auth_LoginIdentifier`
does. It carries `allowAdminCreateUserOnly` as its own function, because **Cognito's field asks the
negative of the question the type asks** and a bool named for the negative is easy to read backwards at
a call site. Both arms are pinned by a test for that reason.

- `platform:signUpMode` config, through the same env / sidecar / stack-config precedence as
  `loginIdentifier`. **Absent means `adminOnly`**, so every existing stack redeploys byte-unchanged —
  and closed is right on its own terms, since a deployment that never asked for self-registration
  should not acquire it by upgrading.
- `--sign-up-mode` on the provisioning script, same variant, same refusal.
- **An unrecognised spelling fails the deploy — for a different reason than 5a's, and the plan should
  not be read as if they were the same.** 5a refuses because the mistake is *permanent*. This one is
  correctable at any time; it refuses because the mistake is *silent*. The default is closed, so a typo
  fails safe — and invisibly: the deploy is green, the config reads as though registration is open, and
  the only symptom is every registration being refused, which surfaces nowhere near the spelling that
  caused it.

**No new stack output, deliberately.** 5a added `identityProviderLoginIdentifier` because the sign-in
attribute is unchangeable, so the value a pool was *born* with has to be readable somewhere other than a
source file that has since moved on. That argument does not transfer: this setting is mutable, so in
auto mode the stack config *is* the current authority and the source tells the truth. (`getUserPool`'s
result type carries neither field, so an output could not have been sourced from a BYO pool anyway —
it would have read `unknown` there, exactly as 5a's does.)

*Evidence:* `reventless/aws` builds warning-free; **862 tests in 74 suites green** (up 11). Verified by
deletion twice — inverting `allowAdminCreateUserOnly` turns 4 tests red, and making `parse` default
past an unknown spelling instead of refusing turns 4 red.

### Step 5c — refusing a replacement instead of performing one, **named and not built**

5a stops a *typo* from creating the wrong pool. It does **not** stop a deliberate edit of
`platform:loginIdentifier` on a live stack from replacing the pool and emptying it — Pulumi will plan
that replacement and carry it out.

Not built, because the only mechanism that refuses is `protect: true` on the resource, and `protect`
also blocks `pulumi destroy` until someone unprotects it. The OSS demo stacks are torn down routinely,
so protecting unconditionally trades a rare irreversible loss for constant friction on stacks that
*want* to be destroyed. The shaped answer is the one
`Auth_ActiveRolePoolAttachment` already demonstrates — a resource that reads what is deployed, compares,
and refuses on disagreement — and it costs a dynamic provider.

Recorded here so it is a decision rather than a gap somebody later reads as an oversight. The stack
output added in 5a is what makes the disagreement visible in the meantime.

Leave `preventUserExistenceErrors: ENABLED` as it is on both pool paths — anything built on this
capability has to reproduce that property rather than inherit it, so it is worth keeping visible.

## Verification

- A plugin declaring the need and a platform provisioning nothing fails the deploy gate — the gate is
  the point of the arm, and it is what `Geocoding` and `Messaging` already demonstrate.
- `Capabilities.none` answers `Unavailable` on every operation, asserted the way the existing
  `geocode` / `messaging` refusals are.
- A local `createPrincipal` writes `.reventless/users.yaml` and a restarted process sees the account.
  Appending to the file is the recommendation: visible, greppable, survives a restart, and matches how
  developers already work with it. It races two processes — record that rather than pretend otherwise;
  the file is already shared with the seed runner.
- Round-trip on both platforms: create, add to group, remove, delete.
- ✅ **A spec field declaring `AllowAnonymous` either reaches an anonymous caller on AWS or fails the
  deploy — never deploys green meaning `AllowAuthenticated`.** Held by five tests in
  `AppSync_AdapterTest`, one of which pins the *contrast* between the two permissions rather than the
  throw, so re-collapsing the arms cannot pass by also deleting the refusal.
- **A token carrying a domain-id claim produces an `Identity.userId` that is not the `sub`, and a token
  without one produces an `Identity.userId` that is exactly the `sub`.** Both arms, held as tests at
  `Auth_Cognito`'s two entry points — the second is what protects every `@owner` field already written,
  and it is the arm that will look redundant to a later reader and is not.
- Full build warning-free and the whole suite green.

## Honesty ledger

- **Read off code:** `Platform_Stack.res`'s `identityProviderId` rename and its outputs, and its
  `preventUserExistenceErrors: ENABLED` (lines 148, 236), `allowAdminCreateUserOnly: true` (190) and
  `usernameAttributes: ["email"]` (207); `CapabilityNeed.t`'s two arms and its object-store exclusion
  note; `Capabilities.t` carrying only `geocode` and `messaging`, and `Capabilities.none`'s two
  refusing arms; `Util_Cognito_Runtime.signUpIfMissing`'s silent catch and its comment;
  `UserStore.res`'s read-only YAML hydration; `Auth_ActiveRoleStore`'s derived store name.
- **Measured in-repo 2026-09-10 (Step 0), replacing what was asserted:** that `usernameAttributes` is
  fixed at pool creation — `UpdateUserPoolRequest` cannot express it, `CreateUserPoolRequest` can. Also
  that `AdminCreateUserConfig` *can* be updated in place, and that the Pulumi AWS schema's
  `replaceOnChanges` is unpopulated for every resource in the provider.
- **Measured in-repo 2026-09-10 (Step 2), replacing this plan's own claim of a clean slate:** that
  `Identity.userId` is the Cognito `sub` on both AWS entry points, and that it is persisted by three
  shipped paths — `meta.user` on every stored event, every `@owner`-stamped command field, and the
  active-role row key. This plan asserted the opposite; the code says otherwise and the code is right.
- **Measured in the vendored SDK types 2026-09-10 (Step 2):** that `ListUsers` cannot filter custom
  attributes, so domain → provider cannot be delegated to the provider; and that `Schema` is on
  `CreateUserPoolRequest` only, while `AddCustomAttributes` exists as its own operation — which is what
  makes the remedy applicable to a live pool.
- **Measured in-repo 2026-09-10 (Step 3), replacing this plan's own description of the gap:** that
  `ownedComponents` and `clientDoor` do not exist — `CapabilityManifest.entry` is `{kind, key,
  declaredBy}`; that `Authorization.permission` already publishes `AllowAnonymous`; that
  `AppSync_Adapter` collapses `AllowAuthenticated | AllowAnonymous` to one group-less Cognito directive
  while the local resolvers call `isAllowed` and honour the distinction; that the only `isAllowed` in
  `reventless/aws/src` is on the Postgres query path, so mutations have no runtime check; and that
  `AppSync.GraphQLApi.authenticationType` has no anonymous arm and no `AppSync_ApiKey` binding exists.
- **Still asserted from outside this repo — three claims, all narrow:** that a replaced pool cannot have
  its users carried across, since Cognito exports no password material, so a migration re-registers
  everybody (narrower than what Step 0 started with, and it decides only *how bad* a replacement is, not
  whether one happens); that a `custom:` attribute is emitted into the id token for an app client
  granted read access to it; and that an AppSync API key expires, with a maximum lifetime of about a
  year, which is what makes Step 3's anonymous door an operational commitment rather than a directive.
  The token claim is Step 2's hot path, so **verify it against a real token before building on it** — if
  it is wrong, the provider → domain direction needs the store too, and the store moves onto the request
  path, which is the one thing the direction split was chosen to avoid.
- **Design proposal, not validated:** every ReScript block here is illustrative shape, not code that
  compiles. The operation set is argued from what the shipped capabilities look like plus one unbuilt
  consumer, and a second consumer can still invert which half was load-bearing.
- **Not investigated:** GDPR erasure of a principal whose registration never completed, and whether the
  AppSync Events API's auth config tolerates an unauthenticated mutation on the same API.
