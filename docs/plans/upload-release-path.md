# Plan: releasing an uploaded object — the missing half of the upload contract

**Date:** 2026-08-01
**Repo:** reventless-core — the neutral upload contract, the AWS presign service and
store provisioning, and the local dev-platform routes.
**Companion:** the client-side adapter that calls the release operation is tracked in
its own plan in the consuming UI repo. Nothing here depends on that plan landing: the
contract, the service and the local routes stand on their own.
**Status:** Steps 1–4 implemented (route B, domain API, single service B1) — builds
clean and unit/HTTP tests green across `aws`, `local`, `seed`, `seed-aws`. Steps 5
(sweeper) and 6 (offline reconciliation) remain staged/backlog. The deploy + browser
acceptance checks (1–5, 7-on-AWS) await a real deploy.
**Revised 2026-08-01:** route **B** chosen — mint and release move behind the
**platform GraphQL API** — over the earlier recommendation of route A (verify a bearer
token inside the Function-URL Lambda). The reasoning is recorded under
[How mint and release are exposed](#how-mint-and-release-are-exposed); the steps,
acceptance checks and risks below are all written for B.
**Builds on:** [served-buckets.md](./done/served-buckets.md) (the mint → store → serve
loop), [platform-capability-provisioning-stage-2.md](./done/platform-capability-provisioning-stage-2.md)
(declaration-driven object stores),
[declared-object-stores-without-host-ui-bundle.md](./declared-object-stores-without-host-ui-bundle.md)
(store endpoints as first-class outputs).

## The gap

The upload contract has a mint side and no release side. A caller POSTs
`{fileName, contentType}`, receives `{uploadUrl, storageRef}`, PUTs the bytes — and
from that moment the object is permanent. Nothing in the framework can remove it.

Every abandoned upload therefore accumulates:

- a form filled in and cancelled,
- a value replaced before the command was sent (the second pick wins; the first
  object stays),
- a file taken back off a multi-value field,
- a tab closed between the PUT and the command that would have referenced the ref,
- a retried upload after a transient command failure.

None of these are edge cases; they are the ordinary shape of filling in a form. The
result is a store whose contents drift away from the events that are supposed to
describe them — the one property an event-sourced platform is selling.

**Verified live (2026-08-01)** on the hybrid example's `alpha` stack: the declared
store's bucket has **no lifecycle configuration at all**
(`GetBucketLifecycleConfiguration` → `NoSuchLifecycleConfiguration`) and holds 66
objects under the `productImages/` prefix. Nothing reaps them, and nothing can.

## Why "add a DELETE route" is the wrong shape

Three properties of the service as it stands make the obvious fix unsafe.

1. **The mint side is anonymous.** The Function URL is created with
   `authorizationType: FunctionUrl.None`
   ([Upload_Presign_S3.res](../../reventless/aws/src/adapter/Upload/Upload_Presign_S3.res)),
   and the handler *decodes* a bearer token without verifying its signature —
   `decodeJwtSub` exists only to namespace the object key
   ([Upload_Presign_S3_Ops.res](../../reventless/aws/src/adapter/Upload/Upload_Presign_S3_Ops.res)).
   Today that is a write-only surface. Bolting deletion onto it makes an
   unauthenticated endpoint destructive.

2. **The service cannot tell a referenced object from an unreferenced one.** Only the
   event log knows whether a ref was ever committed. A release route that takes a
   `storageRef` on trust will delete a live, referenced object as cheerfully as an
   abandoned one — and the damage surfaces later, as a broken image on a page nobody
   was editing.

3. **The caller is not a source of truth about abandonment.** At the endpoint, "I
   uploaded this a second ago and changed my mind" and "delete that other thing" are
   the same request.

Worth stating plainly because this plan has to touch it either way: (1) is already an
exposure on the *mint* side. An anonymous caller can put arbitrary bytes, with an
arbitrary `Content-Type`, under a prefix that CloudFront serves **same-origin with the
deployed UI**. Route B (below) closes this **structurally** — there is no anonymous
surface left once mint moves behind the authenticated platform API — rather than by
bolting a verifier onto the surface that is the problem.

## The decision this plan turns on

Abandonment has two populations, and one mechanism cannot serve both:

- **The client knows, and is still there.** A pick replaced, a file removed, a form
  cancelled. Seconds old, same session, same identity. Wants an immediate, confirmable
  release.
- **The client never got to say.** Tab closed, network died, upload finished after
  navigation. Nobody will ever ask. Wants a sweeper.

### Options considered

1. **A release route that trusts the ref it is given.** Smallest diff, and the one
   this plan exists to reject — see the three properties above.
2. **Staging prefix + promote-on-commit.** Mint into `{prefix}/staging/…`; a reader of
   committed events copies the object to its permanent key. Strongest guarantee —
   nothing permanent exists until an event references it — but it makes the ref the
   caller stored different from the key the object lives at, touches every write path,
   and needs a promoter in the hot path of every commit. Rejected as the primary: a
   large, invasive mechanism for a problem that a scoped rule solves.
3. **Mint-time identity + an age-scoped release rule, with a tag-based sweeper for the
   remainder.** Chosen. Split into stages below, because the two halves have very
   different costs.

### The rule that makes an immediate release safe

The service releases an object only when **all** of these hold:

- the caller is **authenticated** — under route B this is the platform API's existing
  Cognito authorizer, so authentication is decided *before* the resolver runs and the
  verified `sub` arrives in the resolver's identity context (no token is decoded, and
  there is no unverified-token path to get wrong);
- the key sits under **that caller's own identity prefix** — `{servedPrefix}/{sub}/…`,
  which is exactly what the mint side already writes from the caller identity;
- the object is **younger than a short release window** (`LastModified`, default 15
  minutes, configurable at `make` time);
- the key is under **this service's own store prefix** — enforced in the resolver and
  matched by its IAM grant.

An object that a command committed is, in the case that matters, both older than the
window and (usually) another identity's. The rule is checkable entirely server-side,
needs no knowledge of the event log, and introduces no new state. What it cannot do is
release something abandoned an hour ago — that is the sweeper's job, and the honest
division of labour between the two.

### How mint and release are exposed

Two routes were considered; **B is chosen**.

- **A — verify the token in the Function-URL Lambda.** Keeps the contract shape every
  caller already speaks (`POST {fileName, contentType}` → `{uploadUrl, storageRef}`),
  and the seed's optional-bearer path
  ([Seed_Upload.res](../../reventless/seed/src/Seed_Upload.res)) becomes required
  rather than restructured. Cost: a real JWKS-backed verifier (issuer, audience,
  `token_use`, clock skew, key caching) — `aws-jwt-verify` rather than hand-rolled —
  and therefore a **new runtime dependency that has to reach the Lambda through the
  layer/archive machinery** (`Util_Bundle`, the ESM resolve hook), which is exactly
  where this service has historically broken (the serialized-closure / SDK-skew failure
  that made it an EntryPoint module in the first place).
- **B — move mint and release behind the platform GraphQL API.** *Chosen.*
  Authentication is then AppSync's existing Cognito authorizer and the caller identity
  arrives in the resolver context: **no new verifier, no new dependency in the fragile
  archive, and no anonymous surface left at all.** The anonymous Function URL and the
  unverified `decodeJwtSub` are deleted rather than hardened. Bytes still go direct to
  S3 — only the presign *metadata* (and the release *command*) move onto the API; the
  data plane is untouched.

**Which API — corrected during implementation (2026-08-01).** The plan first said the
*platform* API, reasoning that mint/release are operational, not domain, mutations.
Implementation found the platform API is **Admin-group gated end to end**: `Platform.res`
builds its schema with `injectAwsAuthAll(Platform_AdminApi.baseFragment, ~group="Admin")`,
stamping `@aws_auth(cognito_groups: ["Admin"])` on every field (no per-field exemption),
and the local mirror wraps every platform resolver in `requireGroup("Admin")`. Uploads
are a **regular authenticated-user** operation — the whole premise of this plan is
ordinary users filling forms — so Admin-gating them is wrong, and the seed and clients
connect to the **domain** API, not the platform one. The two mutations therefore land on
the **domain** API's platform-owned base fragment (`domainBaseFragment` — the canonical
owner that also carries `Platform_ping`), which is **not** Admin-decorated and so takes
the API's default `AllowAuthenticated` auth: any authenticated Cognito user, exactly the
intended audience. They remain clearly namespaced platform operations (`Upload_Presign` /
`Upload_Release`), not aggregate/DCB commands, and are hand-authored on the base rather
than generated from a plugin folder.

**Why B over A.** A closes the anonymous-mint exposure by *adding* a verifier to the
surface that is the problem; B removes the surface. A's cost lands squarely on this
service's one documented failure mode — a new dependency in the archive — which B
avoids entirely (the presign Lambda keeps its current, working S3-presigner archive
with no dependency added). Identity is decided in **one** mechanism (the Cognito
authorizer every other API call already uses) instead of a second, parallel
JWKS-verification path with its own issuer/audience/skew/key-cache config to keep in
sync. And the two operations land on the **platform API**, which already hosts exactly
this kind of operational, non-domain mutation (`Plugin_Activate`, `Plugin_Deactivate`,
the cloner mutation — [Platform_AdminApi.res](../../reventless/core/src/admin/Platform_AdminApi.res)) —
not on the domain API, where aggregate/DCB commands live.

A's headline advantage was continuity — "the contract shape stays, so no caller
changes." That advantage is weaker than it first appears: the **seed is already
GraphQL-native** (its whole purpose is seeding a platform through its public GraphQL
command API, so a mutation *fits its existing transport better* than a bespoke Function
URL does), and the **client release adapter is new code regardless** (the release side
does not exist yet on the client — the companion UI-repo plan writes it fresh either
way). The honest cost of B is therefore that mint changes transport for the seed and
the client — a real but small, one-time change on two known callers — in exchange for
deleting an anonymous surface and dodging the archive-dependency fight.

### Sub-decision: one service with a `store` argument, or one per store — **B1 chosen (2026-08-01)**

Mint and release both need S3 credentials scoped to a store's prefix (a presigned PUT
inherits the signer's IAM; a release does `DeleteObject` + a head/attributes read).
There are two ways to carry that under B; **B1 is chosen**. B2 is recorded below as the
conservative alternative that was not taken.

- **B1 — one platform presign/release Lambda, taking `store` as an argument.**
  *Chosen.* Two fields on the platform API — `Upload_Presign(store, fileName,
  contentType)` and `Upload_Release(store, storageRef)` — bound to a single Lambda data
  source, whose IAM covers every declared store's `{bucket}/{prefix}/*`. The cleanest
  contract (the client passes the store it declares; nothing derives a per-store
  endpoint), and it collapses the current per-store presign services into one platform
  service.
  The per-store IAM split was introduced against an **anonymous** wildcard presigner —
  its blast radius was "anyone can presign a write anywhere." Under B that
  justification is largely dissolved: the caller is authenticated and never supplies
  the object key — the resolver derives it from the *verified* `sub` and the
  *validated* `store`, so a wide-scoped grant is only reachable through a bug in the
  resolver, not by a caller. Union IAM here is defense-in-depth relaxed, not a
  reintroduced exposure.
- **B2 — keep one Lambda per store (the current shape), each an AppSync data source.**
  Preserves the documented least-privilege split verbatim: each store's service can
  reach only its own prefix, even under a handler bug. Cost: the platform schema grows
  two fields *per store* (their names encode the store), and the seed/client keep a
  store→field map — the `uploadEndpoints` map repurposed from URLs to field names, so
  `endpointFor`'s four-row resolution and its test survive nearly verbatim.

Both are honest; **B1 was chosen** for the cleaner contract and the fact that B removes
the exposure the split defended against. The steps below are written for B1; the `(B2)`
parentheticals mark where B2 would have differed and can be ignored.

## Steps

### Step 1 — move mint behind the platform API (prerequisite)

- Add an `Upload_Presign` mutation to the platform API, backed by a Lambda data source,
  following the `createResolvers` + Lambda-data-source pattern the admin and
  CommandGenerator resolvers already use
  ([CommandGeneratorResolvers_AppSync.res](../../reventless/aws/src/adapter/CommandGenerator/CommandGeneratorResolvers_AppSync.res),
  `Platform.res:1220`). The field entry is hand-authored alongside the admin entries in
  [Platform_AdminApi.res](../../reventless/core/src/admin/Platform_AdminApi.res),
  named via `Api_Naming.adminField` — it is a platform operation, not a generated
  plugin field.
- Rework `Upload_Presign_S3_Ops` to read an **AppSync resolver event**
  (`{arguments: {store?, fileName, contentType}, identity}`) instead of a
  `functionUrlEvent`. Take `sub` from `identity` (verified by the authorizer); **delete
  `decodeJwtSub` and the header-decoding `identityPrefix`** — the identity prefix is now
  built from the verified `sub`. Keep the S3-presigner archive exactly as it is (bare
  `@aws-sdk/*` imports through the resolve hook): **no dependency is added**.
- In `Upload_Presign_S3.make`, **delete the Function URL and its `cors` block** and
  return the Lambda handle for the platform to attach as a data source; CORS and auth
  now belong to the platform API, not to this service.
- Thread the store→prefix/bucket mapping the resolver needs into the Lambda's
  environment at deploy time (Platform.res already has each store's bucket and prefix in
  scope where the presign services are created, `Platform.res:1589`/`:1834`).
- Retire `config.json`'s `uploadEndpoint`/`uploadEndpoints` URL fields — the client
  already has the platform API endpoint. (B2 keeps a store→field-name map here instead.)
- **Breaking:** the mint *transport* changes — a caller POSTing to the old Function URL
  stops working and must call the `Upload_Presign` mutation. In this repo that is the
  seed ([Seed_Upload.res](../../reventless/seed/src/Seed_Upload.res)) and the local dev
  path; the client is new code. Wants a release note.

### Step 2 — the release mutation

- Add an `Upload_Release` mutation on the platform API, resolved by the same per-store
  (B2) or single (B1) Lambda as mint, dispatching on the resolver's field name.
- Release input: the `storageRef` the mint returned (plus `store` under B1). Enforce the
  four conditions above in the resolver, in that order, and return a **typed result**
  carrying a distinct, non-leaky reason per refusal — `unauthenticated`, `not_yours`,
  `too_old`, `not_in_store` — rather than a generic GraphQL error, so the client learns
  *why*. A release that silently no-ops is the failure mode this plan is trying to
  remove. (`unauthenticated` is largely structural now — the authorizer rejects first —
  but the resolver still guards against a missing identity.)
- **One ref per request.** A field that holds many refs releases each one as it is
  dropped, which is what a caller does anyway — a file is taken off a list one at a
  time. Batching is a later optimisation over the same rule, not a different contract,
  and a batch that half-succeeds needs a per-ref result shape that nothing needs yet.
- IAM: add `s3:DeleteObject` and the head/attributes read the age check needs, scoped to
  the same `{bucket}/{servedPrefix}/*` expression the put grant already uses (per store
  under B2; the union of declared store prefixes under B1) — the prefix scoping is what
  keeps a release confined to the store(s) this service owns.
- **CORS/response headers:** these now belong to the platform API's AppSync
  configuration, not to a handler branch — the Function-URL double-header hazard the
  earlier draft warned about (a handler emitting its own `access-control-allow-origin`
  so AWS sends `*, *`) **cannot occur under B**, because the resolver returns a value and
  AppSync formats the HTTP response. The discipline the earlier edit encoded is
  preserved by construction; there is no response branch left to get it wrong.
- Deleting an already-absent key is success, not an error: release is idempotent, and a
  client retrying a release it already made is not an error.

### Step 3 — local dev parity

- Register `Upload_Presign` and `Upload_Release` on the local **platform** GraphQL
  server ([PlatformGraphQL_Server.res](../../reventless/local/src/adapter/PlatformGraphQL_Server.res))
  via `DomainGraphQL_Server.registerMutations(~sdlFields, ~resolvers)`, backed by
  `LocalObjectStore`, so the client and seed call the identical mutation in dev.
- Add `LocalObjectStore.delete(~key)`; the `Upload_Release` resolver calls it. The
  presign resolver returns `{uploadUrl, storageRef}` where both are the same-origin
  `/{prefix}/{key}` (mint is unchanged locally — bytes still go direct via the existing
  `PUT /{prefix}/{key}` route, which stays). The old `POST /__inmemory/upload` HTTP
  route is removed in favour of the mutation; **no `DELETE /{prefix}/{key}` HTTP route
  is added** — release is a mutation now, not an HTTP method on the served path.
- The dev store is a process-local map with no identities and no clock to speak of; the
  release resolver enforces the *shape* of the rule (key must be under a served prefix)
  and not the identity/age conditions, and says so in its comment. Dev parity is about
  the client seeing the same contract, not about reproducing AWS's guarantees.

### Step 4 — contract, tests, docs

- Unit-test the release rule as a pure decision (key, caller sub, object age, store
  prefix) → allow/deny reason, independent of S3 and of AppSync — the same way
  `Seed_Upload.endpointFor` is testable without a running service. The transport moved;
  the decision function is unchanged in shape.
- GraphQL test over the local platform routes for the full loop: `Upload_Presign` → PUT
  bytes → GET → `Upload_Release` → GET (404).
- Update the seed's `uploadAsset` to mint via the mutation and PUT the returned
  `uploadUrl` (the PUT step is unchanged); adjust `endpointFor`/`unresolvedReason` for
  the chosen sub-decision (dropped under B1; store→field map under B2).
- Document the release half of the contract wherever the mint half is documented, and
  state the guarantee precisely: **release is best-effort and time-boxed; it is not a
  general delete API, and no object a committed event references is reachable through
  it.**

### Step 5 (staged) — the sweeper

For everything a client never got to release. Mint tags the object
`reventless:pending`; something that observes committed events strips the tag from the
refs it sees; a bucket lifecycle rule expires objects still tagged after N days.

Staged separately and deliberately: it needs (a) a tag written at mint time (in the
presign resolver) that the client cannot omit, (b) a component that reads committed
events and knows which fields are storage refs — the framework *does* know, since
`@storageRef` declarations reach the schema as `x-reventless-semantic-target`, but
nothing consumes them at runtime today, and (c) a lifecycle policy on a bucket created
with `protect: true`, where a wrong rule deletes referenced objects wholesale. Each of
those is a decision in its own right; sizing them into Step 2 would bury them.

### Step 6 (backlog) — offline reconciliation

A maintenance command that lists a store's objects, extracts every storage ref the
event log ever committed, and reports the difference. This is the only mechanism that
can *prove* an object is unreferenced, which makes it the right shape for an
operator-run tool and the wrong shape for a request handler. It also gives Step 5 its
acceptance evidence.

## Acceptance checks

1. An unauthenticated `Upload_Presign` call is refused by the platform API's authorizer
   (no anonymous Function URL exists to probe any more — the surface is gone, which is
   its own acceptance evidence).
2. A presigned PUT still round-trips for an authenticated caller, and the ref still
   resolves through the serving distribution.
3. A caller can release an object it minted seconds ago via `Upload_Release`; a `GET`
   through the distribution then 404s.
4. `Upload_Release` refused for: another identity's key, a key older than the window, a
   key outside the store's prefix — each with its own typed reason.
5. Every browser-facing check above is run **from a browser**, not from a CLI GraphQL
   probe. A command-line client sends no `Origin`, so it sees neither the preflight nor
   the CORS response headers AWS/AppSync inject only for a cross-origin request — which
   is how this service once passed every command-line probe while failing every real
   upload. At minimum: the cross-origin `Upload_Presign`/`Upload_Release` calls succeed
   from a browser origin with exactly one `access-control-allow-origin` on each
   response.
6. The local dev platform routes answer the same mutations; the GraphQL test covers the
   full loop.
7. Seeding still works end to end via the mutation (it is the one non-browser caller of
   the contract).

## Risks

- **The breaking change is the mint *transport*, not merely requiring auth.** A caller
  POSTing to the old Function URL stops; the seed and client move to the mutation. That
  is the point, but it wants a release note, and the seed change must land in the same
  cut as the service change (they are one contract).
- **No new archive dependency — the historical failure mode is avoided, not managed.**
  This was A's chief cost and the reason B was chosen. But converting the presign Lambda
  from a Function-URL target to an AppSync data source changes its *event shape* and its
  invocation path; the archive dependencies are unchanged, yet the cold-start path still
  deserves an on-AWS check rather than only a green `preview`.
- **B1 relaxes the documented per-store IAM split** (union write/delete across declared
  store prefixes on one Lambda). Justified because B removes the anonymous surface that
  split defended against and the key is server-derived from a verified identity — but it
  is a deliberate loosening, and B2 remains the conservative alternative if
  defense-in-depth against a resolver bug is wanted.
- **The window is a policy, not a guarantee.** Too short and a slow client cannot
  release what it just uploaded; too long and it starts to overlap objects a command
  has committed. 15 minutes is a starting value, not a derived one.
- **Idempotent release hides a wrong ref.** Deleting an absent key answering success
  means a caller passing a garbled ref hears "released". Acceptable — the alternative
  is an error that a retry turns spurious — but it is the reason Step 6 exists.

## What this plan does not do

- It does not make deletion a general capability of the object-store contract. There
  is no "delete this object" primitive at the end of it, on purpose.
- It puts mint and release on the **domain** API's platform-owned base (not the plugin
  subgraphs and not the Admin-gated platform API — see "Which API" above): they are
  namespaced platform operations available to any authenticated user, not aggregate/DCB
  commands and not admin operations.
- It does not touch objects referenced by committed events — nothing here can reach
  one, and Step 6 is a report rather than a reaper.
- It does not version or soft-delete. The store buckets are created at the account's
  default (versioning off), and turning versioning on is a one-way, cost-changing
  decision that belongs to a deployment.
