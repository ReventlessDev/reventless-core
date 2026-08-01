# Plan: releasing an uploaded object — the missing half of the upload contract

**Date:** 2026-08-01
**Repo:** reventless-core — the neutral upload contract, the AWS presign service and
store provisioning, and the local dev-platform routes.
**Companion:** the client-side adapter that calls the release route is tracked in its
own plan in the consuming UI repo. Nothing here depends on that plan landing: the
contract, the service and the local routes stand on their own.
**Status:** Proposed — not started.
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
deployed UI**. That is worth closing on its own merits; a release route makes closing
it mandatory.

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

The service deletes an object only when **all** of these hold:

- the caller is **authenticated** (a *verified* token, not a decoded one);
- the key sits under **that caller's own identity prefix** — `{servedPrefix}/{sub}/…`,
  which is exactly what `identityPrefix` already writes at mint time;
- the object is **younger than a short release window** (`LastModified`, default 15
  minutes, configurable at `make` time);
- the key is under **this service's own store prefix** — already what its IAM policy
  can reach, and now enforced in the handler too rather than left to IAM.

An object that a command committed is, in the case that matters, both older than the
window and (usually) another identity's. The rule is checkable entirely server-side,
needs no knowledge of the event log, and introduces no new state. What it cannot do is
release something abandoned an hour ago — that is the sweeper's job, and the honest
division of labour between the two.

### How the caller is authenticated

Two routes, and this is the one open decision in the plan:

- **A — verify the token in the Lambda.** Keeps the contract shape every caller
  already speaks (`POST {fileName, contentType}` → `{uploadUrl, storageRef}`), and the
  seed's optional-bearer path
  ([Seed_Upload.res](../../reventless/seed/src/Seed_Upload.res)) becomes required
  rather than restructured. Cost: a real JWKS-backed verifier (issuer, audience,
  `token_use`, clock skew, key caching) — `aws-jwt-verify` rather than hand-rolled —
  and therefore a new runtime dependency that has to reach the Lambda through the
  layer/archive machinery (`Util_Bundle`, the ESM resolve hook), which is where this
  service has historically been fragile.
- **B — move mint and release behind the platform GraphQL API.** Authentication is
  then AppSync's existing Cognito authorizer and the caller identity arrives in the
  resolver context: no new verifier, no anonymous surface left at all. Cost: the
  contract changes shape for every caller including the seed, and the platform API
  grows two service mutations. Bytes still go direct to S3 either way — only the
  presign metadata moves.

**Recommendation: A**, on continuity grounds — the upload contract is consumed by more
than one client and by the seed, and B rewrites it for all of them. Revisit if the
verifier's bundling cost turns out to be the usual fight with the layer.

## Steps

### Step 1 — authenticate the mint side (prerequisite)

- Verify the bearer in `Upload_Presign_S3_Ops`; reject unauthenticated presign
  requests with 401 rather than minting into the empty identity prefix.
- Keep `identityPrefix` as the key namespace, now derived from a verified `sub`.
- Thread the issuer/audience the platform already knows (the Cognito pool and client
  ids are in scope at `deployPlatform`) into the service's environment.
- **Breaking:** any caller that uploads anonymously stops working. In this repo that is
  only the dev/local path and any seed run without a session; the hybrid example's seed
  already passes `~authToken` from its client.

### Step 2 — the release route

- Extend the handler's event type with `requestContext.http.method` and dispatch:
  `POST` mints (unchanged), `DELETE` releases.
- Release input: the `storageRef` the mint returned. Enforce the four conditions
  above in the handler, in that order, and answer with a distinct, non-leaky reason
  per failure (`unauthenticated`, `not_yours`, `too_old`, `not_in_store`) — a release
  that silently no-ops is the failure mode this plan is trying to remove.
- IAM: add `s3:DeleteObject` and the head/attributes read the age check needs, both
  scoped to the same `{bucket}/{servedPrefix}/*` expression the put grant already uses
  — the prefix scoping is what keeps one store's service unable to touch another's.
- CORS: add `DELETE` to `allowMethods`; `allowHeaders` already carries
  `content-type` and `authorization`.
- Deleting an already-absent key is success, not 404: release is idempotent, and a
  client retrying a release it already made is not an error.

### Step 3 — local dev parity

- `LocalObjectStore.delete(~key)` plus a `DELETE /{prefix}/{key}` route on the dev
  server, so the same contract answers in dev
  ([DomainGraphQL_Server.res](../../reventless/local/src/adapter/DomainGraphQL_Server.res)).
- The dev store is a process-local map with no identities and no clock to speak of;
  it enforces the *shape* of the rule (key must be under a served prefix) and not the
  identity/age conditions, and says so in its comment. Dev parity is about the client
  seeing the same contract, not about reproducing AWS's guarantees.

### Step 4 — contract, tests, docs

- Unit-test the release rule as a pure decision (key, caller sub, object age, store
  prefix) → allow/deny reason, independent of S3 — the same way
  `Seed_Upload.endpointFor` is testable without a running service.
- HTTP test over the local routes for mint → PUT → GET → DELETE → GET (404).
- Document the release half of the contract wherever the mint half is documented, and
  state the guarantee precisely: **release is best-effort and time-boxed; it is not a
  general delete API, and no object a committed event references is reachable through
  it.**

### Step 5 (staged) — the sweeper

For everything a client never got to release. Mint tags the object
`reventless:pending`; something that observes committed events strips the tag from the
refs it sees; a bucket lifecycle rule expires objects still tagged after N days.

Staged separately and deliberately: it needs (a) a tag written at mint time that the
client cannot omit, (b) a component that reads committed events and knows which fields
are storage refs — the framework *does* know, since `@storageRef` declarations reach
the schema as `x-reventless-semantic-target`, but nothing consumes them at runtime
today, and (c) a lifecycle policy on a bucket created with `protect: true`, where a
wrong rule deletes referenced objects wholesale. Each of those is a decision in its own
right; sizing them into Step 2 would bury them.

### Step 6 (backlog) — offline reconciliation

A maintenance command that lists a store's objects, extracts every storage ref the
event log ever committed, and reports the difference. This is the only mechanism that
can *prove* an object is unreferenced, which makes it the right shape for an
operator-run tool and the wrong shape for a request handler. It also gives Step 5 its
acceptance evidence.

## Acceptance checks

1. An unauthenticated presign request is refused (deploy + `curl`, no token → 401).
2. A presigned PUT still round-trips for an authenticated caller, and the ref still
   resolves through the serving distribution.
3. A caller can release an object it minted seconds ago; a `GET` through the
   distribution then 404s.
4. The same request refused for: another identity's key, a key older than the window,
   a key outside the store's prefix — each with its own reason.
5. Cross-origin release works from a browser origin (preflight passes with `DELETE`).
6. The local dev routes answer the same contract; the HTTP test covers the full loop.
7. Seeding still works end to end (it is the one non-browser caller of the contract).

## Risks

- **Requiring auth is the breaking change here**, not the release route. Any caller
  minting anonymously stops; that is the point, but it wants a release note.
- **The verifier's bundling** is where this service has broken before (the serialized
  closure / SDK skew that made it an EntryPoint module in the first place). Adding a
  dependency to that archive deserves a cold-start check, not just a green deploy.
- **The window is a policy, not a guarantee.** Too short and a slow client cannot
  release what it just uploaded; too long and it starts to overlap objects a command
  has committed. 15 minutes is a starting value, not a derived one.
- **Idempotent release hides a wrong ref.** Deleting an absent key answering success
  means a caller passing a garbled ref hears "released". Acceptable — the alternative
  is a 404 that a retry turns into a spurious error — but it is the reason Step 6
  exists.

## What this plan does not do

- It does not make deletion a general capability of the object-store contract. There
  is no "delete this object" primitive at the end of it, on purpose.
- It does not touch objects referenced by committed events — nothing here can reach
  one, and Step 6 is a report rather than a reaper.
- It does not version or soft-delete. The store buckets are created at the account's
  default (versioning off), and turning versioning on is a one-way, cost-changing
  decision that belongs to a deployment.
