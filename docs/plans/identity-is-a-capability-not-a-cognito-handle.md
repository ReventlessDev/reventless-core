# Plan: identity is a capability, not a Cognito handle

**Date:** 2026-09-10
**Status:** Step 0 ✅ **measured 2026-09-10 — the answer is yes.** Changing the login identifier
replaces the pool and empties it, which made it the workstream's most urgent item; **Step 5a ✅ shipped
the same day** and it is no longer a countdown. Step 5b turned out to be free and is not urgent, and
5c is named-and-not-built. **Steps 1 and 4 ✅ shipped 2026-09-10** — the declaration, the plugin door,
the refusing arm and the deploy gate, with `setActiveRole` decided *out* of the capability. **Steps 2
(the mapping store) and 3 (the client door) are next**, and nothing has written a principal yet, so
Step 2's no-second-chance decision is still genuinely open.
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

## Step 2 — the persisted reference: none, and this is the load-bearing line

**A domain event must never persist a Cognito `sub`, a pool id, or any provider-shaped user id.** What
the log holds is the domain's own opaque `userId`; the mapping to the provider's id lives in the
capability's own store, outside the event log. A reference already written into a million events is
permanent, and a log full of provider ids cannot be migrated to another provider — which would make the
replaceability this whole capability exists for a fiction.

**Decide where that mapping store lives before writing to it.** Which store, who provisions it, and
what happens when it disagrees with the provider (a principal deleted out-of-band) are unspecified.
This has the same no-second-chance property as the object store's key layout: get it wrong and the fix
is a migration of the one table that cannot be rebuilt from the log.

## Step 3 — the client door

A GraphQL field on the platform API rather than a bare endpoint, re-registered by the local platform
over its own backend — the way portability is demonstrated rather than asserted, as `Upload_Presign`
already does for the object store.

**One thing no existing capability door needs: these doors must be callable unauthenticated**, because
being authenticated is what a caller is trying to become. On AWS that is an `@aws_auth` decision
differing from every other mutation the plugin publishes; locally it is a resolver-level decision. A
component that brings a door currently cannot declare that door's auth posture — the manifest carries
`ownedComponents[].clientDoor` and nothing about who may knock. Either extend it here or record the
gap explicitly; do not leave it to each author.

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

**What is deliberately still missing:** Steps 2 and 3. There is no backend on either platform, and
that is why the gate refuses rather than warns. In particular **nothing writes a principal yet, which
keeps Step 2's no-second-chance decision genuinely open** — the mapping store's shape is still free,
because no row has been written under a layout that would have to be migrated.

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

### Step 5b — self-service sign-up (not urgent, and Step 0 is why)

`allowAdminCreateUserOnly: true` is still hard-coded. `AdminCreateUserConfig` **is** in
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
- **Still asserted from outside this repo, and now the only load-bearing outside claim:** that a
  replaced pool cannot have its users carried across — Cognito exports no password material, so a
  migration re-registers everybody. Narrower than what Step 0 started with, and it only decides *how
  bad* the replacement is, not whether one happens.
- **Design proposal, not validated:** every ReScript block here is illustrative shape, not code that
  compiles. The operation set is argued from what the shipped capabilities look like plus one unbuilt
  consumer, and a second consumer can still invert which half was load-bearing.
- **Not investigated:** GDPR erasure of a principal whose registration never completed, and whether the
  AppSync Events API's auth config tolerates an unauthenticated mutation on the same API.
