# Plan: an uploaded object is provisional until an event claims it

**Date:** 2026-08-02
**Repo:** reventless-core only — the mint side of the upload service, a claim component driven by
declared storage-ref fields, and the store bucket's lifecycle policy. No client change: a caller
that mints and PUTs exactly as it does today gets the new behaviour.
**Status:** Steps 1–4 implemented. Builds clean (zero warnings) and the full suite is green
(294 suites / 2649 tests). Step 1's verification question was settled against a live scratch
bucket before anything was written — see the note under Step 1. Step 3 ships **off**: no
store expires anything until a deployment names it, which is the sequencing §Step 4
describes. The on-AWS acceptance checks (2, 3, 5) await a real deploy plus the claimer
running long enough to observe.
Promotes **Step 5 (staged) — the sweeper** of
[upload-release-path.md](./upload-release-path.md) into its own plan, because each of the three
pieces that step names is a decision in its own right and sizing them into it would bury them.
**Builds on:** [upload-release-path.md](./upload-release-path.md) (mint and release behind the
platform API; the age-scoped release rule this complements),
[served-buckets.md](./served-buckets.md) (the mint → store → serve loop).

## The gap this closes

The release path covers the population **the client knows about and is still there for**: a pick
replaced, a file removed, a form cancelled — seconds old, same session, same identity, released on
request inside a 15-minute window.

It cannot cover the other population, and said so: *"the client never got to say. Tab closed,
network died, upload finished after navigation. Nobody will ever ask. Wants a sweeper."* Nothing
collects those today. Verified live on the hybrid example's `alpha` stack when that plan was
written: the store's bucket has no lifecycle configuration at all
(`GetBucketLifecycleConfiguration` → `NoSuchLifecycleConfiguration`) and holds 66 objects under
`productImages/`.

The obstacle is not deletion, it is **knowledge**. In the served-bucket design an upload lands
directly at its permanent, publicly-served key, so a referenced object and an abandoned one are
byte-identical neighbours under the same prefix. No age rule and no prefix rule can separate them,
and a lifecycle rule written on either would eventually delete a live image.

## The decision: mint as pending, claim on commit, expire what stays pending

Three moves, each small, which together make the difference *visible to S3*:

1. **Mint tags the object `reventless:pending=true`.** Written server-side at presign time, not by
   the caller.
2. **A claim component strips the tag** when it sees a committed event whose payload carries that
   storage ref.
3. **A lifecycle rule expires objects still tagged pending after N days.** Untagged objects — every
   claimed one, and every object minted before this exists — are outside the rule entirely.

The shape of the mechanism is the shape of the invariant: *an object nobody committed a reference
to is provisional, and provisional things expire.* The store stops accumulating exactly the
population the release path cannot reach, and it does so without a request handler ever having to
decide whether a ref is live.

**Not the staging-prefix design.** Minting into `{prefix}/staging/…` and copying to a permanent key
on commit gives a stronger guarantee, and was considered and rejected in
[upload-release-path.md](./upload-release-path.md#options-considered): it makes the ref the caller
stored different from the key the object lives at, touches every write path, and needs a promoter
in the hot path of every commit. That decision stands. This plan is the tag-based half of the
option that was chosen, which was always staged to arrive second.

**Safety direction, stated once.** Every mechanism below fails toward *keeping* objects. An untagged
object cannot be expired; a claim that never runs leaves a tag, which is the one way this can
delete something referenced — so the tag's meaning is deliberately "not yet claimed", never "safe
to delete", and §Risks is about that single failure mode.

## Step 1 — mint tags the object

The presign resolver adds the tag to the `PutObjectCommand` it signs, so the object carries it from
the moment the bytes land. The caller does not opt in and cannot opt out.

**Verify first, because it decides the shape:** whether the SDK hoists `x-amz-tagging` into the
presigned URL's query string (the tag applies with no client cooperation — transparent, and what
this plan assumes) or leaves it as a signed header the client must send verbatim (every existing
caller's PUT would start failing with a signature mismatch — a breaking contract change, and a
different plan). A one-off presign-and-`curl` against a scratch bucket answers it before anything
is written.

If it turns out to need client cooperation, the fallback keeps the property without the breakage:
an S3 `ObjectCreated` notification on the store prefix invoking a small tagger. Asynchronous and
one invocation per upload, but no caller changes at all and the same end state. The claim component
and the lifecycle rule are identical either way, so this choice is contained in Step 1.

**Verified 2026-08-02 against a live scratch bucket — the transparent case holds, and the
fallback was not needed or built.** Presigning a `PutObjectCommand` carrying `Tagging` puts
`x-amz-tagging` in the **query string** and leaves `X-Amz-SignedHeaders=host`, so nothing is asked
of the client: a `curl -X PUT` sending only `Content-Type` returned 200, and `GetObjectTagging` on
the result showed `reventless:pending=true`. Two more of the plan's mechanisms were confirmed on
the same bucket before being written — a lifecycle rule filtered on `And{Prefix, Tags}` is accepted
and reads back intact, and `PutObjectTagging` with an empty `TagSet` untags an object and succeeds
again on an already-untagged one (Step 2's replay case). The scratch bucket was deleted afterwards.

The signer's IAM grant gains `s3:PutObjectTagging` alongside its existing `s3:PutObject` on
`{bucket}/{servedPrefix}/*` — a presigned request carries the signer's permissions, so tag-on-put
fails without it.

## Step 2 — the claim component

The piece that "knows which fields are storage refs" — and the framework already does know,
declaratively. `@storageRef` reaches the field's JSON schema as
`x-reventless-semantic-target: {store, plugin?}`
([SuryToJsonSchema.res:168-179](../../../reventless/core/src/components/Api/SuryToJsonSchema.res#L168-L179)),
emitted from the `StoredIn` payload. So the set of event fields that can hold a ref is derivable
from the plugin structure, not hand-listed:

- **Which events to observe** — only event types with at least one `StoredIn` field. A platform
  whose plugins declare no store provisions no claimer at all.
- **Where the refs sit inside one** — the field path, including arity: a `string` field holds one
  ref, an `array<string>` field holds many. Both are already distinguishable in the schema and the
  extractor reads them the same way the annotation writes them.
- **Which store each belongs to** — the `store` (and optional `plugin`) on the target, resolved to
  the qualified name the upload service already keys `UPLOAD_STORES` by. A ref that does not
  resolve to a declared store is left alone rather than guessed at.

The component reads committed events and, for each ref extracted, removes the pending tag. Three
properties it needs, and one it does not:

- **Idempotent.** Untagging an untagged object, or an object that is gone, is success. Replays,
  retries and at-least-once delivery all become non-events.
- **Scoped.** It only ever touches keys under a declared store's served prefix — the same check the
  release rule makes, for the same reason.
- **Observable.** How far behind it is must be a metric, because lag is the failure mode that
  deletes data (§Risks). An alarm on it is part of the step, not a follow-up.
- **Not ordered, and not consistent-read.** The object always exists before the event that
  references it — the PUT precedes the command — so there is no race to design against.

Where it runs is the one open choice: a platform-level subscriber over the committed event stream,
provisioned like the upload service itself when any store is declared. It is deliberately *not* a
plugin's concern — a ref minted by one plugin can be referenced by another's event, and no plugin
owns the store's contents.

## Step 3 — the lifecycle rule

A rule on each store bucket, filtered to the pending tag, expiring after N days. The binding
carries what this needs already (`lifecycleRule` with `tags`, `prefix` and `expiration.days` —
[S3_Bucket.res:41-52](../../../rescript/pulumi-aws/src/S3/S3_Bucket.res#L41-L52)).

Two constraints that shape it:

- **The buckets are created with `protect: true`,** and a wrong rule deletes referenced objects
  wholesale. So the rule is filtered on *both* the tag and the store's served prefix, never on the
  prefix alone, and it is written per declared store rather than once per bucket.
- **N is generous and opt-in.** Long enough that a claim outage is noticed and fixed before the
  first object is due (days, not hours), and the rule is off unless the store's declaration turns
  it on. A store that wants to accumulate forever is a legitimate choice and stays the default until
  a deployment says otherwise.

## Step 4 — the evidence, before the first expiry

[upload-release-path.md](./upload-release-path.md)'s **Step 6 (backlog) — offline reconciliation**
is what makes enabling Step 3 safe, and this plan is the reason to pull it forward: a maintenance
command that lists a store's objects, extracts every storage ref the event log ever committed, and
reports the difference. It is the only mechanism that can *prove* an object is unreferenced.

Run against a store after the claimer has been live a while, it answers the question the lifecycle
rule is about to answer destructively: **is every object still tagged pending genuinely
unreferenced?** A single false positive there is a bug found on a report instead of on a page.

Sequenced as: Steps 1–2 land and run with **no lifecycle rule at all** (tags accumulate, nothing is
deleted, the claimer's correctness is observable) → reconciliation confirms the tagged set is the
unreferenced set → Step 3 turns the rule on, one store at a time.

## Acceptance checks

1. A presigned PUT round-trips unchanged for a caller that knows nothing about tags, and the
   resulting object carries `reventless:pending=true`. — **met**, live against a scratch bucket
   (see Step 1).
2. A command committing that ref results in the tag being gone, within the claimer's stated lag.
   — **awaits a deploy.** The decision half is unit-covered (`Upload_ClaimTest`).
3. An object whose ref is never committed still carries the tag an hour later. — **awaits a
   deploy**; it is an observation over time, not something a test can assert.
4. Replaying the same committed event leaves the object untagged and reports success. — **met**:
   `PutObjectTagging` with an empty `TagSet` succeeded twice on the scratch bucket, and the
   handler skips the write entirely when the tag is already absent.
5. An object minted before this change (no tag) is untouched by the rule — checked against the 66
   existing `productImages/` objects, which must all survive. — **awaits a deploy.** Structurally
   assured (the rule's filter requires the tag), and the reconciliation report counts exactly this
   population as *unreferenced, untagged — outside the rule*.
6. A ref pointing outside a declared store's prefix is refused by the claimer rather than acted on.
   — **met** (`Upload_Claim_S3_Ops.resolveTarget`, covered in `Upload_ClaimTest`).
7. Reconciliation reports zero referenced-but-tagged objects before any lifecycle rule is enabled.
   — **enforced rather than checked once**: `seed:reconcile` exits non-zero while any store has a
   referenced-but-tagged object, and no store expires anything until a deployment names it.

## Implementation notes

Four things the plan left open, and how they were settled:

- **Where the claimer runs.** Per **plugin stack**, not the platform stack: the event log tables
  and their streams live in the plugin's stack, and that is what it subscribes to. The store side
  (bucket, served prefix) crosses in from the platform stack's existing `objectStores` export.
  Still not a plugin's *domain* concern — a ref minted by one plugin can be referenced by
  another's event — but it has to be provisioned where the streams are.
- **Which channel it reads.** DynamoDB streams, which is the default event-topic publisher for
  both aggregate and DCB event logs. An SNS-backed event log declaring a ref field is recorded as
  a gap and named in a deploy warning rather than skipped in silence — its objects would keep the
  tag forever, which reads as working right up until a store enables expiry.
- **The lag metric.** The stream consumer's own `IteratorAge`, alarmed at an hour over three
  five-minute periods. No custom metric: the number the plan asks for already exists.
- **How a store opts in.** A deployment setting, not a declaration — `@storageRef("productImages")`
  says a store is needed and says nothing about retention. `pendingUploadExpiryDays:
  "{plugin}.{store}=days"`, per store, absent by default, with a malformed entry ignored rather
  than defaulted.

One bug surfaced on the way: `@storageRef` on an `array<string>` field declared **nothing**. The
ppx attaches the marker to the element type, and `Plugin_Structure` read the field schema directly,
so a multi-valued store was never provisioned — the same silence as not writing the annotation.
Both readers now go through `StorageRef.getFieldStore`, which looks through the array wrapper and
reports the arity the claimer needs anyway.

## Risks

- **Claim lag is the one way this deletes live data.** If the claimer stops and nobody notices for N
  days, referenced objects expire. Everything above is arranged against it — generous N, opt-in per
  store, a lag alarm as part of Step 2, reconciliation before enabling — but it is the risk that
  justifies the whole sequencing, and no amount of care makes it zero. A deployment that cannot
  monitor the claimer should not enable Step 3.
- ~~**Tag-on-put may not be transparent.**~~ **Closed.** Verified live before anything was
  written: the SDK hoists the tag into the query string and a naive PUT still lands it. Doing it
  first was cheap; assuming the answer would not have been.
- **Object tags cost.** S3 charges per tagged object per month. Negligible at demo scale, worth
  stating before a store with millions of objects adopts it.
- **The claimer must not become a general event consumer.** Its input is narrow by construction
  (only event types with a declared storage-ref field). If it grows toward "read everything", it has
  turned into a projection and belongs in that machinery instead.
- **Two mechanisms now delete objects**, on different evidence: the release rule on identity and
  age, this on absence of a claim. They must not disagree — an object released inside the window is
  simply gone before the sweep ever considers it, which is consistent, but any future third
  mechanism needs the same check.

## What this plan does not do

- It does not add a general "delete this object" primitive; that exclusion from
  [upload-release-path.md](./upload-release-path.md) stands.
- It does not move where an object lives — no staging prefix, no promote-on-commit, no change to
  the ref a caller stores.
- It does not version or soft-delete; expiry is deletion, on buckets created with versioning off.
- It does not reach objects referenced by committed events — by construction, since those are
  exactly the ones whose tag has been stripped.
