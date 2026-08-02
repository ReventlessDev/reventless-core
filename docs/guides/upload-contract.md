# The upload contract: mint, store, serve, release, claim

An object store declared by a `@storageRef` field is filled through a small,
provider-neutral contract. The same shape answers on AWS (a presigned S3 PUT fronted
by CloudFront) and on the local dev platform (a process-local store), so one client
path serves both.

## The four operations

Bytes always travel **direct to the store** — only the presign *metadata* and the
release *decision* go through the GraphQL API.

1. **Mint** — `mutation Upload_Presign(store, fileName, contentType): { uploadUrl, storageRef }`
   The caller names the qualified `{plugin}.{store}` it declares; the service returns a
   short-lived `uploadUrl` (a presigned PUT on AWS; a same-origin `/{prefix}/{key}`
   locally) and the `storageRef` a command will store.
2. **Store** — `PUT uploadUrl` with the raw bytes. Unauthenticated: presigned on AWS,
   open on the local route.
3. **Serve** — the `storageRef` is a same-origin `/{prefix}/{key}` the UI renders
   directly; the store is fronted read-only (CloudFront on AWS, the dev server locally).
4. **Release** — `mutation Upload_Release(store, storageRef): { released, reason }`
   removes an object the caller uploaded but never committed (a replaced pick, a
   cancelled form, a closed tab).

Both mutations live on the **domain** GraphQL API and take its default
`AllowAuthenticated` auth — any authenticated user can mint and release their own
uploads. They are *not* on the Admin-gated platform API, and *not* aggregate/DCB
commands.

## Authentication

There is no anonymous surface. `Upload_Presign`/`Upload_Release` are authenticated by
the API's Cognito authorizer, and the verified caller identity (`sub`) reaches the
resolver. The mint side namespaces every object under the caller's own identity prefix,
`{servedPrefix}/{sub}/…`, which is what makes an ownership check on release possible.

## When a release is allowed

The service deletes an object only when **all** of these hold, and answers with a
distinct, non-leaky reason otherwise:

| Condition | Reason on failure |
|---|---|
| The caller is authenticated | `unauthenticated` |
| The key is under this store's served prefix | `not_in_store` |
| The key is under the caller's own identity prefix | `not_yours` |
| The object is younger than the release window | `too_old` |

The release window defaults to **15 minutes** and is configurable at `make` time
(`~releaseWindowSeconds`). Deleting an already-absent key is **success**, not an error:
release is idempotent, so a client retrying a release it already made is not a failure.

## The guarantee, precisely

**Release is best-effort and time-boxed. It is not a general delete API, and no object
that a committed event references is reachable through it.** An object a command
committed is, in the case that matters, both older than the window and another
identity's, so the age and ownership checks keep it out of reach. What release *cannot*
do is reclaim an object abandoned long ago — nobody is left to ask for it. That is what
the claim mechanism below is for.

## An object is provisional until an event claims it

Release covers the abandonment a client is still around to report. The other population —
tab closed, network died, upload finished after navigation — nobody will ever ask about,
so the platform decides it without being asked.

1. **Mint tags the object** `reventless:pending=true`, written into the presigned PUT's
   signature. The tag is hoisted into the URL's query string, so a caller that PUTs
   exactly as it always has still gets tagged bytes and cannot opt out.
2. **The claim component strips the tag** when a committed event carries the ref. It
   reads the event log streams of every event log whose events declare a `@storageRef`
   field — and only those — and untags each ref it finds under a declared store's prefix.
   Untagging an untagged or absent object is success, so replays and at-least-once
   delivery are non-events.
3. **A lifecycle rule expires what stays tagged**, filtered on the tag **and** the store's
   served prefix.

The tag means *"not yet claimed"*, never *"safe to delete"*. Read the direction of failure
off that: a claim that does not happen leaves a tag on, and only step 3 turns a lingering
tag into a deletion — which is why step 3 is off by default.

### Enabling expiry

Off unless a deployment names the store, one store at a time:

```yaml
# Pulumi.local.yaml, or REVENTLESS_PENDING_UPLOAD_EXPIRY_DAYS
pendingUploadExpiryDays: "Catalog.productImages=30, Ordering.receipts=14"
```

A store not named here accumulates forever, which is a legitimate choice and the default.
Objects minted before the claim component existed carry no tag and are outside any rule.

**Before enabling it for a store, run the reconciliation report** (`pnpm run seed:reconcile`
in the hybrid example). It lists the store, scans every event log, and reports four
populations — the one that matters is *referenced but still tagged pending*, which must be
zero. It exits non-zero when it is not. The report deliberately does **not** read the
`@storageRef` declarations: it scans event payloads for any string under the store's prefix,
so a ref on an unannotated field — which the claimer would never see and never untag —
shows up as a problem instead of being confirmed as "unreferenced" by the same blind spot.

### The failure mode worth monitoring

Claim lag is the one way this deletes live data: if the claimer stops and nobody notices
for N days, referenced objects still carry the tag when the rule comes for them. The
deploy alarms the claimer's `IteratorAge` (default: more than an hour behind, for three
five-minute periods). **A deployment that cannot monitor that alarm should not enable
expiry.**

One gap to know about: the claimer subscribes to DynamoDB-stream-backed event topics,
which is the default for both aggregate and DCB event logs. An event log publishing
through SNS instead carries refs the claimer never sees; the deploy logs a warning naming
it, and no store should enable expiry while that warning appears.

## Local dev parity

The dev platform has no bucket, so mint/release resolve against a process-local store
(`LocalObjectStore`) and the bytes travel over `PUT`/`GET /{prefix}/{key}` routes on the
dev server. Parity is about the client seeing the **same contract**, not reproducing
AWS's guarantees: the dev store has no identities and no clock, so release enforces only
the *shape* of the rule (the key must be under a served prefix), not the identity/age
conditions.

The claim mechanism has **no local counterpart**, deliberately. It is invisible to the
client — no mutation, no field, nothing a caller can observe — so there is no contract for
dev to be at parity with, and a simulated pending-set would only be a reimplementation of
S3 object tagging with nothing depending on it.
