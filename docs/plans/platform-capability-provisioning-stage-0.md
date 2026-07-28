# Plan: platform capability provisioning — Stage 0 (derivation only)

**Date:** 2026-07-28
**Status:** Implemented + build-verified 2026-07-28 (`5f87c57c7`) — NOT yet deploy-verified. All six
steps landed; build clean, suite 2240/2240. Example platform roots 79 → 24 lines (hybrid), 29 → 14
(the other two).

**The acceptance test is still outstanding**, and it is the deploy-time one this plan named: a
`pulumi preview` against an existing stack must show the uploads bucket updating **in place**, with
tag additions and a new PAB, and *not* being replaced — a replacement destroys live objects. The
logical name is unchanged, so it should hold, but nothing here proves it. Tag coverage against the
Resource Groups Tagging API filter that `ReventlessSeedAws_Reset` uses is likewise unverified against
real infrastructure, and that is the defect this plan exists to fix.

One decision made against the risk table: encryption and versioning are left at the AWS/account
defaults rather than set explicitly, matching the framework's own buckets (`TaskBucket_S3`, the
plugin bundle bucket). Versioning is one-way once enabled, and the S3 binding's
`kmsMasterKeyId` is non-optional so an explicit SSE block would send an empty key. This also keeps
the preview diff to exactly tags + PAB, which is what makes the update-in-place check readable.

`servedBuckets` was removed outright rather than kept as an override escape hatch: a grep confirmed
the example roots were its only consumers, and retaining it would reintroduce the prefix mismatch the
derivation exists to make unrepresentable.
**Repos:** `reventless-core` only.
**Analysis:** [platform-main-capability-provisioning.md](../analysis/platform-main-capability-provisioning.md) §3.2, §3.3, §7 Stage 0.

## Why this first

Stage 0 introduces **no new concepts** — no capability model, no declaration primitive, no
inference. It is pure derivation inside `deployPlatform` plus framework helpers for the two
resources the example platform roots hand-write. It is worth doing on its own merits, ahead of
every other stage, because it repairs two defects that are live today:

1. **`seed:reset` never empties the uploads bucket.** Every framework-created resource carries
   `AWS.Tags.make(~name, ~kind, ~role, ~scope, …)`; the hand-written `online-shop-uploads` bucket
   in [platform-aws/src/Main.res:42-55](../../examples/online-shop-hybrid/platform-aws/src/Main.res#L42-L55)
   carries none, and `platform-aws/Pulumi.yaml` sets no `aws:defaultTags`. The guarded store-wipe
   discovers targets **only** through `reventless:platform` + `reventless:environment` tag filters
   against the Resource Groups Tagging API
   ([ReventlessSeedAws_Reset.res:176-220](../../reventless/seed-aws/src/ReventlessSeedAws_Reset.res#L176-L220)).
   A "wipe the store" therefore leaves every uploaded image behind while the events referencing
   them are gone.
2. **The `servedBuckets` prefix trap.** The presign service is provisioned as
   `Upload_Presign_S3.make(~bucketName)` with no `~servedPrefix`
   ([Platform.res:1539-1546](../../reventless/aws/src/Platform.res#L1539-L1546)), so it takes the
   `"uploads"` default ([Upload_Presign_S3.res:34](../../reventless/aws/src/adapter/Upload/Upload_Presign_S3.res#L34))
   and mints `/uploads/<uuid>` refs. The app must independently restate that constant as
   `servedBuckets[].prefix`. Nothing validates the match: `prefix: "media"` compiles, deploys
   green, and 404s every uploaded image.

Also fixed in passing: the hand-written bucket has no `BucketPublicAccessBlock`, though
[Plugin_Stack.res:434](../../reventless/aws/src/plugin/stack/Plugin_Stack.res#L434) documents the
framework's assumption that a served bucket keeps its own all-true PAB. Account-level S3 defaults
currently cover this, so it is a latent gap rather than a live exposure.

## Scope boundary

**In:** derivation inside `deployPlatform`; two `Capability_*` helper modules that create the
bucket and place index with framework conventions applied; slimming the three example platform
roots.

**Out:** the capability model itself (§5), the `@storageRef` declaration (Stage 1), moving object
stores into plugin stacks (Stage 2), inference and `generate-platform` (Stage 3). The bucket and
index are still created *in* `Main.res` after this plan — just through helpers instead of raw
Pulumi. Ownership does not move.

## Steps

### 1. `Capability_ObjectStore_S3.makeBucket`

New module in `reventless/aws/src/capability/` (new directory). Creates an S3 bucket with the
house standard applied, which the hand-written bucket lacks:

- `AWS.Tags.make(~name, ~kind, ~role, ~scope, …)` — the tags `seed:reset` discovers by. Follow
  [TaskBucket_S3.res:146](../../reventless/aws/src/adapter/Task/TaskBucket_S3.res#L146), which is
  the closest existing analogue (a declared, framework-provisioned bucket).
- `BucketPublicAccessBlock`, all-true, per
  [Plugin_Stack.res:172](../../reventless/aws/src/plugin/stack/Plugin_Stack.res#L172).
- The browser-PUT CORS rules currently written by hand, as the default (overridable via an
  optional `~corsRules`).
- Server-side encryption and versioning defaults, consistent with the framework's own buckets.

Signature returns whatever `deployPlatform` needs to derive `servedBuckets` — at minimum
`{bucket, id, arn, bucketRegionalDomainName}` as `Output`s. Note the repo convention: **never wrap
a Pulumi `Output` in an `option`.**

`protect: true` / `retainOnDelete` is *not* part of this step — that mitigation belongs with
Stage 2, when the bucket's lifecycle starts following a declaration rather than an explicit line
of app code. Note it in the module doc comment as a Stage 2 follow-up.

### 2. `Capability_Geocoding_AwsLocation.makeIndex`

Same treatment for the place index
([Main.res:27-36](../../examples/online-shop-hybrid/platform-aws/src/Main.res#L27-L36)): framework
tags, and `dataSource` / `intendedUse` defaulted to today's `Esri` / `SingleUse` but readable from
Pulumi config, following the `hostUiBaseDomain` precedent
([Platform.res:1464-1484](../../reventless/aws/src/Platform.res#L1464-L1484)). These are licensing,
cost and data-retention decisions and do not belong in application code.

### 3. Derive `servedBuckets` inside `deployPlatform`

`servedBuckets` leaves `hostUiBundleConfig` ([Platform.res:1027](../../reventless/aws/src/Platform.res#L1027)).
`deployPlatform` builds the entry itself from `uploadBucketName` plus the presign service's own
`servedPrefix`, so the prefix is written once and consumed by both sides. This makes §3.2's
mismatch unrepresentable rather than merely discouraged.

The field is currently `servedBuckets?: array<ReventlessInfra.Platform.servedBucket>` and
`Plugin_Stack.res:145` already takes an array with per-entry consumers, so nothing downstream
changes shape — only who populates it.

Because the derivation needs the bucket's `id` / `arn` / `bucketRegionalDomainName` and today only
`uploadBucketName` is threaded, `hostUiBundleConfig` takes the helper's output record in place of
the three upload fields. Net effect on the public API: `enableUploads`, `uploadBucketName` and
`servedBuckets` (three ways of saying one thing) collapse to one optional field.

### 4. Default the remaining derivable fields

- `assetsDir` — default to the resolved `@reventlessdev/reventless-host-shell` dist. The
  `Util_Bundle.resolvePackageRoot(...) ++ "/dist"` line is byte-identical across all three example
  platform roots ([Main.res:20-21](../../examples/online-shop-hybrid/platform-aws/src/Main.res#L20-L21)).
- `bundleVersion` — default to the `~version` already passed to `deployPlatform`.

Both stay overridable.

### 5. Drop the dead Cognito line

[Main.res:18](../../examples/online-shop-hybrid/platform-aws/src/Main.res#L18) calls
`Platform_Stack.resolveCognitoUserPool()`, a process-cached singleton
([Platform_Stack.res:152](../../reventless/aws/src/Platform_Stack.res#L152)) already invoked inside
the functor body at [Platform.res:254](../../reventless/aws/src/Platform.res#L254) and
[Platform.res:1512](../../reventless/aws/src/Platform.res#L1512). It provisions nothing that would
not otherwise exist. Remove from all three example roots.

### 6. Slim the example platform roots

Target shape (§7 Stage 0), 79 → ~12 lines:

```rescript
module Platform = ReventlessAws.Platform.Make()

let uploadBucket = ReventlessAws.Capability_ObjectStore_S3.makeBucket(~name="online-shop-uploads")
let placeIndex = ReventlessAws.Capability_Geocoding_AwsLocation.makeIndex(~name="online-shop-geocoder")

let default = Platform.deployPlatform(
  ~version=Reventless.PackageVersion.fromCaller(),
  ~hostUiBundle={geocoderPlaceIndex: placeIndex, uploadBucket},
)
```

## Verification

- **Tag coverage is the acceptance test.** After deploy, the uploads bucket must be discoverable
  by the same Resource Groups Tagging API filter `ReventlessSeedAws_Reset` uses. Assert it there,
  not only by eyeballing the Pulumi diff — the failure mode this plan exists to fix is precisely
  an operational tool quietly doing nothing.
- `pulumi preview` on `platform-aws` against an existing stack: expect **tag additions and a new
  PAB** on the bucket, and no replacement. Confirm the bucket is not marked for replace — if the
  helper changes the logical name, the bucket is destroyed and recreated with live objects in it.
  Use the same logical name as today, or an explicit alias.
- Serve path unchanged: an uploaded image still resolves at `/uploads/<key>` through CloudFront.
- The other two example platform roots build and preview clean after the same slimming.

## Risks

| Risk | Mitigation |
|---|---|
| **Bucket replacement on the tag/PAB change.** A changed logical name destroys a bucket holding live objects. | Keep the logical name; verify `pulumi preview` shows update-in-place, not replace. This is the one step that must not be reviewed casually. |
| **Removing `servedBuckets` from the public API is a breaking change** for any consumer outside the examples. | Grep for consumers first. The examples are the only known ones; if others exist, keep the field as an escape hatch that *overrides* the derivation rather than deleting it outright. |
| **Encryption/versioning defaults change bucket behavior** for an existing bucket. | Versioning on an existing bucket is one-way (it can be suspended, not removed). Decide explicitly whether Stage 0 turns it on for the existing example bucket or only for newly created ones. |
| Config-driven `dataSource` / `intendedUse` changes the place index's licensing tier if defaults are read wrong. | Defaults must reproduce today's `Esri` / `SingleUse` exactly; assert in the preview diff that the index is unchanged. |

## Follow-ups this plan explicitly does not take

- `protect: true` / `retainOnDelete` on provisioned stores (Stage 2, when lifecycle follows a
  declaration).
- Per-store buckets and per-store presign least-privilege (Stage 2). Today's single presign service
  holds write access to everything.
- The bucket-count ceiling check (§5.3) — needed before Stage 2, not before this.
