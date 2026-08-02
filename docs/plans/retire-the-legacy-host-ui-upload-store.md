# Plan: retire the legacy host-UI upload store

**Date:** 2026-08-02
**Status (updated 2026-08-02):** In progress. **Step 2 deployed** (`3e0f9833a` — protection
cleared; bucket verified empty + `protect=false` in state). **Step 3 committed but NOT pushed/deployed**
(`d27866e5c` — declaration removed; local preview confirmed only the bucket, its public-access block, and
the served-uploads policy delete, declared store untouched). **Outstanding:** confirm no `/uploads/…` ref
remains in the event log (the last precondition), push/deploy Step 3, then **Step 4** — exercise an actual
upload through the declared store (a green deploy does not prove it). The **ordering is the plan**, because
two of the three steps fail as a red deploy rather than as a caught preview if taken out of order.
**Repos:** `reventless-core` only.
**Analysis:** [platform-main-capability-provisioning.md](../analysis/platform-main-capability-provisioning.md) §5.3, §7 Stage 2.
**Builds on:** [declared-object-stores-without-host-ui-bundle.md](./declared-object-stores-without-host-ui-bundle.md)
and [done/platform-capability-provisioning-stage-2.md](./done/platform-capability-provisioning-stage-2.md).

## The gap

The hybrid example's platform root still hand-writes an object store:

```rescript
let uploadBucket = ReventlessAws.Capability_ObjectStore_S3.make(~name="online-shop-uploads")
…
~hostUiBundle={geocoderPlaceIndex: placeIndex, uploadBucket},
```

It is the **last hand-written store in the estate**, and it is the exact shape Stage 2's teardown
exercise identified as a defect. `Capability_ObjectStore_S3.make` defaults `~protect=true` and
`~forceDestroy=false`; a store written by hand takes those defaults and cannot know it is on a
disposable stack, so `destroy` refuses it and the bucket survives the stack — while a *declared*
store beside it deletes cleanly. The example that exists to teach the mechanism is the one
demonstrating its failure mode.

It is also, by the framework's own naming, superseded. `deployPlatform` calls it "the legacy
`hostUiBundle.uploadBucket`" where it folds it into the one domain-API upload service alongside
every declared store.

## What actually holds it in place — and why that has expired

Not Pulumi. The reason is written into `deployPlatform` at the `servedBuckets` construction:

> The legacy hand-configured store is served alongside the declared ones, not replaced by them.
> Refs live in an append-only event log, so the `/uploads/…` values already written there can never
> be rewritten; `uploads` is therefore treated as a store that happens to predate the declaration,
> and keeps its prefix permanently.

That reasoning is correct and it is load-bearing: while a single `/uploads/…` ref survives in a
log that must survive, the store must too. It stops applying the moment no such ref exists.

Three facts say the example is at that point, or one wipe away from it:

- **Nothing targets the store.** Every `@storageRef` in the hybrid example names `productImages`,
  which resolves to the declared store. The only occurrence of `"uploads"` in the tree is
  `Upload_Presign_S3.defaultServedPrefix`. No field mints into the legacy store, so it takes no new
  objects — its contents are strictly historical.
- **The example's log is already owed a wipe** on independent grounds: the `Money` retype makes
  stored catalog events undecodable, and qualifying store key prefixes as `{plugin}/{store}`
  orphaned every object minted under a bare prefix. Both migrations are the same operation —
  `seed:reset` for the owning plugin, then re-seed — and after it no `/uploads/…` ref exists.
- **`uploadBucket?` is optional.** Removing it is a deletion in the example, not an API change:
  every field of `hostUiBundleConfig` is optional, so `~hostUiBundle={geocoderPlaceIndex: placeIndex}`
  compiles unchanged.

So the store's justification is self-expiring, and the wipe that expires it is already scheduled.
This plan is what to do on the other side of it.

## The order is the plan

`protect: true` makes Pulumi **refuse to delete the resource**, and refuse it at apply time. Deleting
the declaration first therefore does not produce a preview that shows a problem — it produces a
deploy that fails partway. That matters more here than it would elsewhere, because a push to `alpha`
publishes *and* deploys, with no review step between preview and apply.

Protection must be cleared **while the resource still exists in the program**. That is one deploy,
and the removal is a second.

The one-deploy alternative is `pulumi state unprotect <urn>` followed by a single removal deploy.
It is rejected: it edits state by hand, it is invisible in the diff, and the example's stack lives
in Pulumi Cloud rather than the self-hosted S3 backend the other stacks use — a different login, so
the operator most likely to attempt it is the one least likely to be already authenticated against
the right backend. Two reviewable deploys cost one extra apply and leave the whole change in the
commit history.

## Steps

### 1. Wipe and re-seed the example, and confirm the precondition

Not this plan's work — it is owed for `Money` and for prefix qualification regardless — but it is
this plan's gate. Afterwards, confirm directly rather than by inference:

- no `/uploads/…` ref remains in the event log;
- the bucket is empty. An empty bucket is what makes step 3 a plain delete: a protected *and*
  non-empty bucket refuses twice, and `forceDestroy` is only needed for the second refusal.

If the bucket is non-empty at step 3 and clearing it is not wanted, add `~forceDestroy=true`
alongside step 2's `~protect=false` — same deploy, no extra step. Prefer emptying it, so the
destructive flag never enters the program even briefly.

### 2. Clear the protection, with the declaration still in place

```rescript
let uploadBucket = ReventlessAws.Capability_ObjectStore_S3.make(
  ~name="online-shop-uploads",
  ~protect=false,
)
```

**Acceptance:** `pulumi preview` shows exactly one in-place update on the bucket and nothing else —
no replacement, no deletion. A replacement here would mean `protect` is not the only thing that
moved, and is a reason to stop.

### 3. Remove the declaration

Delete both the `let uploadBucket = …` binding and the `uploadBucket` field from `~hostUiBundle`,
leaving `~hostUiBundle={geocoderPlaceIndex: placeIndex}`. Delete the comment above the binding with
it — a comment explaining a store that no longer exists is worse than no comment.

**Acceptance:** the preview shows the bucket deleted, its public-access block deleted, and the
`/uploads` prefix dropped from the host-shell distribution's served buckets. The declared store's
own origin, policy and cache behaviour are untouched — they come from `declaredServedBuckets`, a
different array.

### 4. Verify what the shell still does

The point of the example is that uploads keep working, through the declared store alone:

- a command form with a `@storageRef` field mints through `Upload_Presign`, naming the store;
- the minted ref is rooted at the qualified `{plugin}/{store}` prefix;
- it reads back through the shell's own origin.

A green deploy is not evidence of this — the upload input degrades by not registering rather than by
erroring, so it must be exercised, not inspected.

## What this buys

- **The teardown leak closes at its source.** With no hand-written store anywhere, `destroy` on a
  disposable stack removes what it created. The Stage 2 finding stops being a caveat the examples
  themselves violate.
- **The example demonstrates one mechanism instead of two.** A reader currently sees a store
  declared by a field's type *and* a store constructed by hand in the platform root, with nothing in
  the example saying which one to copy. Removing the second answers the question by construction.
- **`servedBuckets` gets one contributor.** The `Array.concat` of the legacy singleton with
  `declaredServedBuckets` becomes just the declared list at every call site in the tree — worth
  noting for whoever next reads that branch, though the code stays as-is (see below).

## Deliberately out of scope

**Deprecating `hostUiBundleConfig.uploadBucket` itself.** After this plan no example uses it, which
makes it tempting to remove in the same pass. It should not be: a platform outside this repo may
hold `/uploads/…` refs in a log that must survive, and for that platform the field is not legacy but
load-bearing — precisely the reasoning quoted above. Retiring it needs a migration story for
existing refs (a served-prefix alias, or an upcaster over stored refs), which is a larger question
than the removal of one example's call. Filing it as a separate plan is the right shape; folding it
in here would couple a five-line example cleanup to a compatibility break.

## Risks

| Risk | Mitigation |
|---|---|
| **The declaration is removed before protection is cleared**, failing the apply partway with a deploy already in flight. | The two steps are separate commits in a fixed order. Step 2's acceptance — one in-place update, nothing else — is the gate on taking step 3 at all. |
| **A `/uploads/…` ref survives the wipe** in some slice the reset does not target, and the delete strands it. | Step 1 confirms absence in the log directly rather than assuming the reset's scope covered it. The reset targets seeded demo data by plugin; a ref written by hand outside that scope would not be caught. |
| **The bucket is non-empty at step 3**, so S3 refuses the delete independently of Pulumi. | Confirmed empty in step 1. `~forceDestroy=true` alongside step 2 is the fallback, deliberately not the default — it is a flag that turns a refusal into silent data loss, and it should not live in an example even transiently. |
| **The removal is read as "uploads were dropped from the example".** | Step 4 exercises the declared-store upload path, and the commit message states that the capability moved rather than went. |
| **Push to `alpha` deploys**, so each step applies as soon as it lands — there is no staging between preview and apply. | Read each preview before pushing, not after. This is the reason the plan is two commits rather than one with a mid-flight decision. |
