# Plan: identity is a capability, not a Cognito handle

**Date:** 2026-09-10
**Status:** Not started. Step 0 is a measurement that decides how urgent Step 5 is; take it first.
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

What does not exist: no arm in the platform capability variant, no member on `Capabilities.t` (which
carries `geocode` and `messaging` and nothing else), no constructor in `CapabilityNeed.t` (two arms —
`Geocoding`, `Messaging`), no refusing arm in `Capabilities.none`, and therefore **no deploy gate**.

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

## Step 0 — measure the one irreversible thing first

`Platform_Stack.res:207` provisions the pool with `usernameAttributes: ["email"]`, hard-coded. The
claim this plan is built on is that the attribute is fixed at pool creation, so changing it **replaces
the pool and destroys every account in it** — which would make "add phone sign-in later" a rebuild and
a user migration rather than a later decision.

That claim is asserted from outside this repo and is not measured in it. **Run `pulumi preview` against
a throwaway pool with the attribute changed** and read whether it reports a replacement. The
recommendation in Step 5 is cheap and right either way; its *urgency* rests entirely on this, so
establish it before treating it as a deadline.

## Step 1 — the declaration

A third arm beside the two that exist, with no payload, for the same reason `Geocoding` has none: one
identity provider per deployment is a real answer. A deployment wanting two pools (staff and customer)
is the `{alternatives, min}` question `Messaging` already answers by publishing channels — not a reason
to parameterise now.

`CapabilityNeed.t` gains `IdentityProvider` with its `toString` / `fromString` spellings, matching the
existing arms' discipline that a persisted structure holds strings so an older reader still decodes a
newer plugin's need.

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

Two settings move onto the capability at provision time rather than staying hard-coded:

- **the login identifier** (today `usernameAttributes: ["email"]`) — a deployment that will ever want
  phone sign-in must say so on its first deploy. An unpleasant constraint to hand a deployer, and much
  cheaper to state than to discover.
- **whether self-service sign-up is permitted** (today `allowAdminCreateUserOnly: true`).

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
- **Asserted from outside this repo — Step 0 exists to settle it:** that `usernameAttributes` is fixed
  at pool creation and that changing it forces a replacement.
- **Design proposal, not validated:** every ReScript block here is illustrative shape, not code that
  compiles. The operation set is argued from what the shipped capabilities look like plus one unbuilt
  consumer, and a second consumer can still invert which half was load-bearing.
- **Not investigated:** GDPR erasure of a principal whose registration never completed, and whether the
  AppSync Events API's auth config tolerates an unauthenticated mutation on the same API.
