# Plan: platform capability provisioning — Stage 2 (declaration-driven object stores)

**Date:** 2026-07-28
**Status:** Proposed.
**Repos:** `reventless-core` only.
**Analysis:** [platform-main-capability-provisioning.md](../analysis/platform-main-capability-provisioning.md) §5.3, §7 Stage 2, §8.
**Builds on:** [platform-capability-provisioning-stage-0.md](./platform-capability-provisioning-stage-0.md)
(framework-provisioned stores) and [done/semantic-type-marker-and-storage-ref.md](./done/semantic-type-marker-and-storage-ref.md)
(the declaration).

## What this closes

Stages 0 and 1 left a deliberate gap, and it is worth naming precisely because it is the whole
reason this stage exists:

```rescript
// catalog — ChangeProductImage.res:13, declares a requirement
ChangeProductImage({productId: string, @storageRef("productImages") imageUrl: string})

// platform-aws — Main.res:19, provisions a bucket
let uploadBucket = ReventlessAws.Capability_ObjectStore_S3.make(~name="online-shop-uploads")
```

Two unrelated strings. Nothing outside tests reads `StorageRef.getStore`, so deleting the annotation
would still leave the bucket, and adding `@storageRef("invoices")` would provision nothing. The
declaration is *stated* but *unhonored*.

Stage 2 makes the declaration the authority: the store a field declares is the store that gets
provisioned, owned by the plugin that declares it, and named after it.

## Gate 1 — the bucket-count ceiling (§5.3)

**Measured 2026-07-28:** 9 buckets in the OSS demo account. AWS's default limit is 100 buckets per
account, adjustable to 1,000 via a quota increase. Note the general bucket-count quota is not
exposed through `service-quotas list-service-quotas --service-code s3` (that returns only
replication/object quotas), so the limit has to be confirmed from the account's Service Quotas
console rather than scripted.

The growth term is `plugins × stores × stacks`, and **stacks is the dangerous factor**: the stack
allowlist already admits `pr-*`, so a per-PR environment multiplies every plugin's every store.
Two plugins with one store each across a handful of long-lived stacks is ~10 buckets; the same
against 20 open PRs is ~40, on top of the framework's own per-stack buckets (host-ui bundle, task
buckets, plugin bundles).

**Decide before writing code**, because it changes the ref grammar:

- **Per-store bucket** — clean IAM boundary, per-store lifecycle, simple deletion. Costs a bucket per
  store per stack against a global namespace.
- **Prefix within one bucket per stack** — one bucket, `{store}/…` prefixes. Bounded count, but
  per-store least-privilege becomes an IAM policy over prefixes rather than over buckets, and a
  store's deletion becomes a prefix sweep rather than a bucket delete.

`StorageRef`'s grammar was deliberately left structural — absolute path, ≥2 non-empty segments, no
traversal — rather than pinning a per-store prefix, precisely so it admits either outcome without a
stored-value migration. Whichever is chosen, the grammar tightens from structural to per-store, and
that tightening is the only ref-format change this stage may make.

**Recommendation:** per-store buckets, with the prefix scheme as the documented fallback if the
account limit turns out to bind. Ephemeral `pr-*` stacks are the pressure, and the cheaper answer
there is to keep PR stacks on the shared-bucket scheme rather than to compromise the model for
long-lived environments.

## Gate 2 — the replacement post-mortem — CLOSED

Recorded here because this stage is where the risk becomes live, and the evidence should not have to
be rediscovered.

The concern: Stage 0 changed how the uploads bucket is constructed (raw Pulumi in `Main.res` → a
framework helper), and a changed logical name would destroy a bucket holding live objects. On the
2026-07-28 deploy of the example stack, `ListBuckets` reported the bucket's `CreationDate` as the
deploy time, which reads as a replacement.

It was not one:

- Deploy log: `~ aws:s3:Bucket online-shop-uploads updating (0s) [diff: ~tags,tagsAll]` — an
  in-place update, tags only, no replace step.
- The bucket holds 128 objects whose oldest `LastModified` is the previous day. Objects cannot
  predate their bucket.

**`ListBuckets`' `CreationDate` is not a reliable "created at"** and must not be used as
replacement evidence. The two signals that are reliable: the Pulumi step verb in the deploy log, and
object `LastModified` timestamps.

This matters for Stage 2 rather than being historical: once a bucket's lifecycle follows a
*declaration*, the replace/destroy path stops being reachable only by editing a line of Pulumi and
becomes reachable by renaming a field. See step 5.

## Naming

A store's bucket must be traceable back to the declaration that required it. Today's
`online-shop-uploads` is not — it names a deployment, not a store, and there is no path from a
`@storageRef("productImages")` field to that string.

**Physical name: `{plugin}-{store}`** (`catalog-productImages`), with Pulumi's suffix for global
uniqueness. The logical name is the same, so the URN is derived from the declaration and a store
rename is a visible replace in review rather than a silent one.

Not to be confused with the framework's other buckets, which keep their existing conventions and are
out of scope here:

- **Task buckets** — `TaskBucket_S3`, named from component + role
  (`importproductsproductimportsbucket`, the `ImportProduct` inbound-translation slice's drop
  bucket). A task bucket is an *ingress* for a slice, not a declared store, and no `@storageRef`
  field points at it.
- **Plugin bundle** and **host-ui bundle** buckets — hosting substrate, not domain storage.

The distinction is worth stating in the module doc: a store is declared by a field's type and holds
values that events reference; a task bucket is wired by a slice and holds transient input.

## Steps

### 1. Collect declared capabilities into `Plugin_Structure`

`Plugin_Structure` already walks component schemas and reads type-carried facts — it calls
`Reference.getTarget` at [:161](../../reventless/core/src/plugin/component/Plugin_Structure.res#L161)
and [:253](../../reventless/core/src/plugin/component/Plugin_Structure.res#L253). Add the same
treatment for `StorageRef.getStore`, collecting a deduplicated set of required stores per plugin.

Walk **commands, events and state** — a store referenced only by a read model still has to exist.
Dedup by `(plugin, store)`: many fields legitimately name one store.

### 2. A `capability` type in `reventless/infra`

```rescript
type capability =
  | ObjectStore({plugin: string, store: string})
  | Geocoding
```

A real variant, in `infra` so both the platform and the plugin stacks reference one nominal type.
Stage 4 grows it; nothing here should make that growth require touching every consumer.

### 3. Provision stores in the plugin stack that owns them

Object stores move out of the platform root into `Plugin_Stack`, beside the plugin's other owned
substrate. `Capability_ObjectStore_S3.make` already applies the house conventions and needs only
the naming change from step 0 plus `~plugin` for attribution — the tags become
`scope=Plugin`, `plugin={plugin}` rather than `scope=Platform`.

The platform keeps only what it needs to *serve*: `deployPlatform` learns the served-store list, not
the buckets themselves.

### 4. Per-store presign, least-privilege

Today one `Upload_Presign_S3` service holds `s3:PutObject` on the single upload bucket
([Platform.res](../../reventless/aws/src/Platform.res), presign provisioning) and mints keys under
one `defaultServedPrefix`. With per-store buckets that becomes one presign service per store, each
scoped to its own bucket.

This is the step that makes the UI able to bind an upload input to a *declared* store rather than to
a name heuristic — the reventless-ui side is currently blocked on exactly these endpoints not
existing. It is also where `StorageRef`'s grammar tightens: the ref a store's service mints becomes
checkable against that store, closing the last gap left open in Stage 1.

**Do not** collapse this into one service with wildcard write across stores; that reintroduces the
blast radius the per-store split exists to remove.

### 5. `protect` / `retainOnDelete` — before, not after

Provisioned stores carry `protect: true` (removable by explicit config opt-out), per
[protecting-prod-infrastructure-resources.md](../analysis/protecting-prod-infrastructure-resources.md).

This is the step that must not be deferred. Stage 0's bucket could only be destroyed by editing
Pulumi; a Stage 2 bucket can be destroyed by **renaming a field**, because the last
`@storageRef("productImages")` disappearing removes the requirement. Gate 2 showed the current path
is safe today — that safety does not survive this stage without `protect`.

Land step 5 in the same commit as step 3. A bucket that exists for one deploy without protection is
a bucket that can be lost in that window.

### 6. The platform API

```rescript
let default = Platform.deployPlatform(
  ~version=Reventless.PackageVersion.fromCaller(),
  ~capabilities=[ObjectStore({plugin: "catalog", store: "productImages"}), Geocoding],
  ~hostUi=Default,
)
```

`~capabilities` is still hand-written here — deriving it is Stage 3. The value of writing it by hand
first is that the list is reviewable and the generator has an existing shape to emit.

## Verification

- **The declaration drives it.** Adding `@storageRef("invoices")` to a catalog command and running
  `pulumi preview` shows a new `catalog-invoices` bucket. Removing it shows the bucket *protected*,
  not destroyed. This pair is the plan's reason to exist; nothing before step 5 demonstrates the
  second half.
- **No replacement of the existing store.** `pulumi preview` on the example stack: the bucket that
  exists today must not be replaced by the move into the plugin stack. Ownership moving between
  stacks changes the URN, so this needs an explicit alias or an import — **verify before applying**,
  and use the two reliable signals from Gate 2 (the step verb, and object timestamps afterwards),
  not `CreationDate`.
- Per-store presign writes only to its own bucket — assert the IAM policy resource, not just that
  upload works.
- Tag coverage: every provisioned store discoverable by the `reventless:platform` +
  `reventless:environment` filter pair, as Stage 0 established.
- Full root build green, suite green, no `.res.mjs` churn beyond intended files.

## Risks

| Risk | Mitigation |
|---|---|
| **Moving the store between stacks replaces it.** The URN changes when ownership moves from the platform root to a plugin stack — the same class of failure Gate 2 investigated, but this time genuinely reachable. | Explicit alias or `pulumi import`. Verify with a preview showing update/import, never replace, before applying to any stack with objects. This is the one step that must not be reviewed casually. |
| **Silent deprovisioning by field rename** (§8). | Step 5's `protect: true`, landed in the same commit as provisioning. Capability removal also becomes a reviewable diff once Stage 3 generates the list. |
| **Bucket ceiling turns out to bind** after per-store buckets ship. | Gate 1 decided before code. The prefix scheme is the documented fallback, and the ref grammar admits it without a stored-value migration. |
| Per-store presign multiplies Lambdas and Function URLs per stack. | Count them in Gate 1's arithmetic alongside buckets — the ceiling question is not only about S3. |
| A store declared by two plugins. | `(plugin, store)` is the identity; two plugins declaring the same store name get two stores. Cross-plugin sharing is the qualified `@storageRef("other.store")` form, which requires the owner to exist — assert it rather than provisioning implicitly. |

## Out of scope

- Stage 3's inference, `capabilities.json`, `generate-platform` and the `deployPlugin` assertion.
  `~capabilities` stays hand-written here.
- Stage 4's wider provider catalogue.
- Stage 5's `UploadableFile.t` — the annotation stays the declaration form.
- Migrating the example's existing objects to a renamed bucket. If Gate 1 picks per-store buckets,
  the existing `online-shop-uploads` store is a rename, and moving 128 live objects is its own
  exercise — do it deliberately, not as a side effect of this stage.
