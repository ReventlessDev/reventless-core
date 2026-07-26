# Plan: Serve an S3 bucket to the UI — reusable "served asset bucket" capability (core)

**Date:** 2026-07-26
**Repo:** reventless-core — the neutral served-bucket contract, the AWS/CloudFront
implementation, the local dev-platform routes, and the hybrid-example integration.
**Companion:** the UI-side pieces (a config escape hatch + an asset resolver + the
local dev upload adapter) are tracked in a separate `served-buckets` plan in the
**reventless-ui** repo.
**Status:** COMPLETE (implementation). Neutral contract + AWS/CloudFront path +
hybrid integration + local dev adapter (Part 2b) all implemented and build-clean;
the local path is verified end-to-end by an HTTP test. The AWS acceptance checks
(200 via CloudFront, 403 direct-S3, browser thumbnail) verify on the next alpha
deploy. Follow-ups live in their own plans: the local dev `config.json`/Vite
wiring in the reventless-ui companion plan, and real seeded images in
[seed-images-to-served-bucket.md](../seed-images-to-served-bucket.md).

## Problem

The upload presign service
([Upload_Presign_S3](../../../reventless/aws/src/adapter/Upload/Upload_Presign_S3.res))
hands the UI a `storageRef` that a command stores and the UI renders — e.g. a
catalog Product `imageUrl` rendered as a thumbnail. Historically that ref was a
**virtual-hosted S3 URL**, which only resolves if the uploads bucket is
**public-read** — a bespoke, security-sensitive, one-off choice, and one every
app that wants to show an uploaded/generated object would reinvent.

There is no reusable way to let a **deployed UI read a private storage bucket's
objects by URL** (uploaded images, generated exports, attachments, thumbnails).

Meanwhile the host-ui already ships exactly the right front door:
[`Plugin_Stack.makeUiBundleDistribution`](../../../reventless/aws/src/plugin/stack/Plugin_Stack.res)
provisions a **CloudFront distribution** that serves the static SPA from a
**private** S3 bucket via **Origin Access Control** — the bucket is locked down
(`BucketPublicAccessBlock` all-true), an OAC is created, the single S3 origin is
wired, and a `BucketPolicy` grants CloudFront read scoped to the distribution.
Serving a **second** private bucket behind the **same** distribution is the
natural, secure, reusable mechanism — and it makes served objects **same-origin**
with the UI.

## Decision

Introduce a generic **served bucket** concept: a deployment declares buckets to
be served **read-only** to the UI under a **path prefix** on the UI's own public
origin, kept **private** (CDN-only read). The UI then addresses objects by a
**same-origin relative URL** `/{prefix}/{key}` — provider-neutral, no base-URL
config, no CORS on the GET path, no public bucket.

Split by layer, so it is reusable and not CloudFront-specific at the seam:

- **Neutral contract** (Part 1): the served-bucket declaration on the host-ui
  bundle config, a same-origin URL convention, and an upload contract that yields
  a directly-renderable served ref.
- **AWS implementation** (Part 2): front each served bucket through the existing
  host-ui CloudFront distribution with OAC + an ordered cache behavior.
- **Local implementation** (Part 2b): the in-memory dev platform satisfies the
  same UI contract with a local store + a same-origin dev-server route + a direct
  upload route — no CloudFront, no presigning.
- **Integration** (Part 3): the hybrid example's uploads bucket becomes a served
  bucket under `uploads/`, retiring the public-read/raw-S3-URL approach.

The key simplifier: because the served bucket sits behind the **same** CloudFront
domain as the SPA, served objects are **same-origin**, so the UI uses relative
URLs and **nothing about CloudFront leaks into config.json**.

## Part 1 — Neutral contract (provider-agnostic)

The reusable seam is three things, none of which know about S3 or CloudFront:
1. the **same-origin URL convention** `/{prefix}/{key}`;
2. a pluggable **upload adapter** on the UI (owned by the reventless-ui plan);
3. **`config.uploadEndpoint`** — where that adapter sends bytes.

`servedBuckets` (step 1) is **not** part of that seam — it is an **AWS-deploy
input**, a Pulumi-typed handle consumed only by the AWS host-ui deploy (Part 2).
A different provider satisfies the same UI contract by other means and never
populates it — the local platform (Part 2b) mounts routes directly instead.

1. **Served-bucket handle + input (AWS-deploy input).** ✅ DONE. A neutral record
   at file scope in
   [`ReventlessInfra.Platform`](../../../reventless/infra/src/types/Platform.res),
   referenced by `hostUiBundleConfig` in
   [aws](../../../reventless/aws/src/Platform.res) and
   [local](../../../reventless/local/src/Platform.res):
   ```rescript
   type servedBucket = {
     prefix: string,                                  // "uploads", "exports", …
     bucketId: Pulumi.Input.t<string>,
     bucketArn: Pulumi.Input.t<string>,
     bucketRegionalDomainName: Pulumi.Input.t<string>,
   }
   // on hostUiBundleConfig:
   servedBuckets?: array<servedBucket>,
   ```
   These four fields are the minimal handle any CDN front needs; the app owns the
   bucket's lifecycle and creation. A single shared nominal type keeps the three
   concrete `hostUiBundleConfig` definitions in agreement. (Local/in-memory
   ignores it, as with the existing knobs.)

2. **Same-origin convention.** Served objects live at `/{prefix}/{key}` on the
   UI's own origin. Default ⇒ the UI uses **relative** URLs; nothing is written
   into config.json.

3. **Upload contract returns a served ref.** ✅ DONE. The upload/presign contract
   yields `storageRef = "/{prefix}/{key}"` (same-origin relative), so a command
   stores a directly-renderable value with no post-processing.

> The UI-side escape hatch for cross-origin topologies (a config `assetOrigins`
> map + an `Assets.resolve` helper) lives in the reventless-ui plan. Same-origin
> deployments — the default — need no UI code because `storageRef` is already a
> resolvable same-origin ref.

## Part 2 — AWS implementation via CloudFront ✅ DONE

6. **Extend `makeUiBundleDistribution`**
   ([Plugin_Stack.res](../../../reventless/aws/src/plugin/stack/Plugin_Stack.res))
   with `~servedBuckets: array<servedBucket>=[]`. For each served bucket:
   - **an origin** `served-{prefix}`: `domainName = bucketRegionalDomainName`,
     `originAccessControlId = oac.id` (reuses the existing bundle OAC — the OAC
     only authorizes CloudFront→S3 sigv4 signing);
   - **an ordered cache behavior**: `pathPattern = "{prefix}/*"`,
     `targetOriginId = "served-{prefix}"`, `viewerProtocolPolicy =
     "redirect-to-https"`, the CachingOptimized policy (immutable uuid keys).
     **Order matters** — served behaviors are **prepended** to
     `orderedCacheBehaviors` so a served path is matched before the SPA-serving
     default and never routed to the bundle bucket;
   - **a BucketPolicy** granting `cloudfront.amazonaws.com` `s3:GetObject` on
     `{bucketArn}/*` with `Condition AWS:SourceArn = <distribution arn>`. The
     served bucket keeps its own `BucketPublicAccessBlock` all-true (app-owned,
     stays private).
   Same distribution ⇒ same origin ⇒ **no base URL in config.json**. With
   `servedBuckets=[]` the origins/behaviors/policies collapse to the pre-existing
   set (empty `Array.concat`/`forEach`), so a hints-less deploy is byte-identical.

7. **Thread `servedBuckets`** ✅ DONE. From `hostUiBundleConfig` →
   [`deployPlatform`](../../../reventless/aws/src/Platform.res) →
   `makeUiBundleDistribution` (the host-ui branch).

8. **`Upload_Presign_S3` returns the served ref.** ✅ DONE. The handler roots the
   object key at a `SERVED_PREFIX` env (default `uploads`, set at deploy) and
   returns `storageRef = "/{key}"` (same-origin relative) instead of the
   virtual-hosted S3 URL. The Lambda still PUTs by `key`. New object keys are
   uuid-based, so no CloudFront invalidation is needed.

## Part 2b — Local platform adapter (dev) ✅ DONE

The same contract works for the in-memory dev platform because the seam is
same-origin URLs + the pluggable upload adapter, not CloudFront. The local
platform already runs its own HTTP server
([DomainGraphQL_Server](../../../reventless/local/src/adapter/DomainGraphQL_Server.res),
port 4000); it had **no object-bucket primitive**, so this added one. Each piece
is the local analogue of an AWS one:

| AWS (Part 2) | Local (Part 2b) |
| --- | --- |
| S3 uploads bucket | a **local object store** — [`LocalObjectStore`](../../../reventless/local/src/adapter/LocalObjectStore.res), a process-local `key → {bytes, contentType}` map; in-process only, no SQLite arm |
| CloudFront `{prefix}/*` behavior via OAC | a **same-origin serve route** `GET /{prefix}/*` in `DomainGraphQL_Server._dispatch`, streaming stored bytes with the object's content type |
| `Upload_Presign_S3` Function URL | a **presign-shaped upload route** `POST /__inmemory/upload` → `{uploadUrl, storageRef}` (both `/{prefix}/{key}`) + a `PUT /{prefix}/{key}` that stores the bytes; no presigning |

11. **Local object store + routes.** ✅ DONE. The store + the presign / PUT / GET
    routes live on the dev server so `/{prefix}/*` resolves and the upload
    endpoint accepts bytes. `servedBuckets` (the Pulumi handle) is **not** used
    locally — the dev server mounts the routes directly, serving the
    `LocalObjectStore` prefixes (default `uploads`). The upload route uses the
    **same presign-shaped contract** as AWS (`uploadUrl == storageRef ==
    /{prefix}/{key}`), so the reventless-ui `FileDropzone` S3 adapter and the seed
    helper are one code path for both providers. See
    [seed-images-to-served-bucket.md](../seed-images-to-served-bucket.md) Part 1.
    Covered end-to-end by
    [ServedBucketHttpTest](../../../reventless/local/tests/adapter/ServedBucketHttpTest.res)
    (presign shape, PUT→GET byte + content-type round-trip, 404 for a missing
    object).

Caveats: dev-only and **ephemeral** (the store is process-local; contents are
lost on restart). It remains optional: an app can run the AWS path in prod and
leave local uploads unused (a `file`/`image` field falls back to a plain text box
locally when no upload endpoint is registered).

## Part 3 — Integration into the hybrid example ✅ DONE

9. **Declare the uploads bucket as served.** In
   [platform-aws/Main.res](../../../examples/online-shop-hybrid/platform-aws/src/Main.res)
   the existing `online-shop-uploads` bucket (private; PUT/POST CORS for the
   browser upload stays) is passed as a served bucket in `hostUiBundle`:
   ```rescript
   servedBuckets: [{
     prefix: "uploads",
     bucketId: uploadBucket.id->Pulumi.Output.asInput,
     bucketArn: uploadBucket.arn->Pulumi.Output.asInput,
     bucketRegionalDomainName: uploadBucket.bucketRegionalDomainName->Pulumi.Output.asInput,
   }],
   ```
   (`enableUploads` + `uploadBucketName` still drive the presign service; the
   served entry adds the CloudFront read path.)

10. **End to end:** a product image dropped in the generated `AddProduct` /
    `ChangeProductImage` form uploads via the presigned PUT, the presign service
    returns `/uploads/<key>`, that ref is stored as `Product.imageUrl`, and the
    Image renderer thumbnails it — fetched through CloudFront from the **private**
    bucket.

## Acceptance

- A deployment listing a served bucket makes its objects fetchable at
  `https://<ui-domain>/{prefix}/<key>` (200 via CloudFront) while the bucket stays
  private (a direct S3 GET is 403).
- In the hybrid example an uploaded product image renders as a thumbnail in the
  browser, served through CloudFront; **no bucket is public-read**.
- No `servedBuckets` ⇒ the distribution and config.json are byte-identical to
  today; the UI is unchanged.
- Reusable: another app serves an exports/attachments bucket by adding one more
  `servedBucket` entry — no UI or framework change, no new binding.
- Provider-neutral: with the local adapter (Part 2b), the **same** UI (relative
  `/{prefix}/{key}` + the FileDropzone adapter) uploads and renders an image in
  `local dev` against a local store — no code change on the UI side, no
  CloudFront, no presigning.

## Notes

- **No new pulumi-aws binding.** OAC
  ([CloudFront_OriginAccessControl](../../../rescript/pulumi-aws/src/CloudFront/CloudFront_OriginAccessControl.res)),
  `BucketPolicy`, and `BucketPublicAccessBlock` already exist and are already used
  by `makeUiBundleDistribution`.
- **Security.** The served bucket is never public; only CloudFront (scoped by
  `AWS:SourceArn`) can read it.
- **CORS.** The served GET path is same-origin ⇒ no CORS. The browser **PUT**
  (upload) still needs the bucket's PUT/POST CORS (already set).
- **Cache.** `{prefix}/*` objects are immutable (uuid keys) ⇒ a long `max-age`
  cache policy is safe.
- **Ordering guard.** The `{prefix}/*` behavior must precede the SPA-fallback so
  served objects aren't rewritten to `index.html`.
- **PPX note (local env).** The auto-ui `@semantic`/`@metric` feature requires the
  per-platform reventless-ppx binary that `bin` resolves (e.g.
  `reventless-ppx-darwin-arm64/ppx.exe`) to be rebuilt from current source; a
  stale one fails read-model specs with "missing semantic metric" on full
  recompile. Refresh it from the freshly-built local fallback when this surfaces.
