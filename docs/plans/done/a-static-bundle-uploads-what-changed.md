# Plan: a static bundle uploads what changed, in one resource

**Status:** ✅ Built and deployed 2026-10-21: [S1](#s1-the-deploy-workflow-takes-a-parallelism)
and [S2](#s2-the-per-file-objects-are-retained-on-delete) in `reventless-aws` 3.0.0-alpha.391,
[S3](#s3-one-resource-uploads-the-directory) and [S4](#s4-docs) in 3.0.0-alpha.392.<br/>
**Touches:** `reventless/aws` (`Plugin_Stack.makeUiBundleDistribution`), the reusable deploy
workflow `.github/workflows/deploy-reventless-aws.yml`, the docs on deploying a UI bundle.

## In plain words

A UI bundle deployed with `makeUiBundleDistribution` becomes one Pulumi `aws:s3:BucketObject`
per file. Each one costs a create or a delete of about ten seconds, and Pulumi runs a bounded
number at once. A bundle's file names carry a content hash, so a rebuild renames most of them:
the update creates every new file and deletes every old one.

That was cheap for a bundle of a few dozen files. A bundle with module-federation remotes beside
it has hundreds: each remote writes one small loader file per shared module. Measured on one
platform stack, the platform's `pulumi up` grew from about 3½ minutes to 8, 13 and over 20 as
its bundle grew; the 13-minute update created 228 objects and changed 253 resources, nearly all
of them bundle files.

The fix is to stop modeling files as resources. One resource uploads the directory: it lists
what the bucket holds, puts what is new or changed many at a time, and deletes what is two
generations old. Pulumi then tracks one resource, however many files the bundle has.

## Steps

Numbered S1 to S4.

### S1: the deploy workflow takes a parallelism

`deploy-reventless-aws.yml` takes `pulumi-parallel`, passed to both `pulumi up` calls as
`--parallel`. Empty keeps Pulumi's own default. A quick win for a caller deploying a large
bundle before S3 lands, and harmless after.

Done when a caller setting it sees `--parallel` in its `pulumi up` lines.

### S2: the per-file objects are retained on delete

Every bundle `BucketObject` gets `retainOnDelete: true`. Nothing is uploaded differently, and
the update that applies it changes state only.

This step exists for [S3](#s3-one-resource-uploads-the-directory). Pulumi deletes a resource
that leaves the program at the end of an update, after it has created the new ones. Replacing
the per-file objects with one upload resource in a single update would upload every file and
then delete each of them again, since they share their keys. A resource retained on delete is
dropped from state and left in the bucket.

Done when a deploy of a stack with a bundle shows the objects updated with no change to
their content, and `pulumi stack export` records `retainOnDelete` on them.

### S3: one resource uploads the directory

A dynamic resource, `StaticBundleUpload`, in the shape of the other dynamic resources in
`reventless/aws` (the SDK imported lazily, nothing captured that holds an Output):

- **Inputs**: the bucket name, and the bundle as a manifest of `{key, contentHash,
  contentType, cacheControl}` per file, built by `Util.StaticBundle.walk` as today, with the
  excluded files dropped as today. The file bodies are read at upload time from the directory.
- **Always updated.** `diff` reports a change on every update, and the update compares the
  manifest with what the bucket holds (`ListObjectsV2`, the content hash kept in each object's
  metadata), so a file removed outside Pulumi, or a stack that skipped
  [S2](#s2-the-per-file-objects-are-retained-on-delete), is repaired by its next deploy.
- **Uploads** what is missing or whose hash differs, sixteen at a time, with the content type
  and cache control the per-file objects carry today.
- **Deletes** the keys of the generation before the previous one: the outputs keep this
  update's keys and the previous update's, and a key in neither is deleted. A reader with a page
  open from the previous deploy can still load its chunks. Keys the resource never uploaded
  (`config.json`, a hints file, served buckets' prefixes) are never touched.
- **The CloudFront invalidation** chains on this resource's output instead of on the per-file
  etags, so it still runs after the new content is in the bucket.

Callers change nothing: `makeUiBundleDistribution` keeps its arguments and result.

Done when a stack that ran S2 deploys with S3 and its `pulumi up` shows one bundle resource
updated, the site serves every file, and an update with an unchanged bundle uploads nothing.

As built: `reventless/aws/src/util/Util_StaticBundleUpload.res`, reusing
`Util_LogGroup_Adopting_Js.mjs`'s helpers for the lazily imported SDK. It compares by MD5, since
`ListObjectsV2` returns ETags but no metadata and a single-part upload's ETag is its MD5. The
deletion rule is `staleKeys`, tested in `tests/Util_StaticBundleUploadTest.res`. Not released
until every stack has deployed S2.

### S4: docs

The comment on `makeUiBundleDistribution`, and the deploy guide's section on UI bundles, say
how the upload works now, and that a stack must deploy S2 before S3.

As built: the comment, and `packages/doc/docs-infrastructure/ui-fragments-deployment.md`.

## Order

[S1](#s1-the-deploy-workflow-takes-a-parallelism) and
[S2](#s2-the-per-file-objects-are-retained-on-delete) ship together. Every stack that deploys a
bundle then runs one deploy with them before
[S3](#s3-one-resource-uploads-the-directory) ships; [S4](#s4-docs) with S3.

## What the first deploys showed

With S1 and S2, a platform stack's update still took 12m51s at `--parallel 64`: every bundle
object was updated though none had changed. The per-file objects pass the file's SHA-256 as
`etag`, and S3 reports an MD5, so each deploy saw a difference on every object and uploaded the
whole bundle again. S3 compares MD5 with MD5, which removes that as well.

## What the switch showed

On the platform stack measured above, with S1 and S2 applied:

| Update | Platform `pulumi up` | Where the time went |
|---|---|---|
| S1 and S2 (`--parallel 64`) | 12m51s | every bundle object uploaded again (the etag mismatch) |
| S3, the switch | 14m24s | 11 minutes dropping 232 retained objects from state, one by one; the upload resource took 12s and put 1 of 232 files |
| After the switch | about 3 minutes expected | what the switch took outside the one-time drop |

On a smaller stack the switch took 38s, its upload resource 1s, with no file put. Both sites
served every file afterwards. The files the per-file objects held stay in the bucket, untracked.

## Risks

- **A stack that jumps from before S2 to S3** loses its bundle files at the end of that update,
  since the per-file objects are deleted after the upload. Its next deploy repairs it, because
  S3 compares with the bucket on every update. The release notes of S3 say to deploy S2 first.
- **Throttling.** Sixteen concurrent puts are well inside S3's request rates; a throttled put is
  retried by the SDK.
- **A dynamic provider's state** holds the manifest, a few hundred short records: small.

## Acceptance

- A bundle of several hundred files deploys in one resource, and an update that changes a few
  files uploads only those.
- No file a reader could still request disappears with the deploy after the one that built it.
