# Plan: SPA Bundle Deployment for `makeUiBundleDistribution`

**Date:** 2026-05-03

**Status:** Phases 1–3 implemented (framework + unit tests). Integration validation against a live AWS deploy is still pending — see "Open follow-ups" at the bottom.

---

## Goal

Extend `Plugin_Stack.makeUiBundleDistribution` so it can deploy a static SPA bundle end-to-end: upload the built assets to its bucket and configure CloudFront for client-side history routing. Today the helper provisions the bucket, OAC, and distribution skeleton but stops short — the bucket is empty after `pulumi up` and prefixed routes 404.

This is framework work in `reventless-aws`. No example app or downstream consumer needs to change beyond passing the new optional arguments.

---

## Background

### What `makeUiBundleDistribution` does today

[Plugin_Stack.res:9-104](../../reventless/reventless-aws/src/Plugin_Stack.res#L9-L104) creates:

- An S3 bucket with `BlockPublicAccess` (private, OAC-only access).
- A CloudFront `OriginAccessControl` for the bucket.
- A CloudFront `Distribution` pointing at the bucket origin with the AWS-managed `CachingOptimized` policy.
- A bucket policy that allows the distribution's service principal to read objects.

It returns `{ distributionUrl, bucketName }`. The caller is responsible for uploading bundle files separately — and in practice no caller does today, so this helper is currently provisioning empty distributions.

### What's missing for a working SPA

1. **Asset upload.** Without `BucketObject` resources for each file in the bundle's `dist/`, the distribution serves 403 on every request. Callers should not have to hand-roll a directory walker; the helper has all the context needed (`pluginId`, `bundleVersion`, `bucket`) and the alternative is everyone copy-pasting a walker.
2. **SPA history fallback.** Modern SPAs use `pushState` routes (`/foo/bar/baz`) that resolve to `index.html` client-side. CloudFront returns 404 for these on first paint because there's no `/foo/bar/baz` object in S3. The standard fix is `customErrorResponses` mapping 403/404 → `responseCode=200, responsePagePath="/index.html"` so the SPA loads and the router takes over.
3. **MIME types.** A naive `BucketObject` upload defaults `contentType` to `application/octet-stream`. Browsers refuse to execute JS served as octet-stream and won't apply CSS; need a per-extension mapping (`.js → application/javascript`, `.css → text/css`, `.html → text/html`, `.json → application/json`, `.svg → image/svg+xml`, `.map → application/json`, `.woff2 → font/woff2`, etc.).
4. **Index document.** The CloudFront distribution today does not declare a `defaultRootObject`. Visiting the root URL returns the bucket's directory listing 403 instead of `index.html`.

---

## Phase 1 — Per-file upload  ✅ Done

### 1.1 Extend the helper signature

```rescript
let makeUiBundleDistribution = (
  ~pluginId: string,
  ~bundleVersion: string,
  ~assetsDir: option<string>=?,        // NEW — path to the built bundle (e.g. "/abs/path/to/dist")
  ~spaFallback: bool=false,            // NEW — see Phase 2
  ~indexDocument: string="index.html", // NEW — see Phase 2.2
): bundleDistribution
```

When `~assetsDir` is omitted the helper behaves as today (provisions infra, uploads nothing) — preserves backwards compatibility for callers that wire their own upload pipeline.

### 1.2 Walk the directory and create one `BucketObject` per file

**Implementation.** A small recursive walker in a new helper module `reventless/reventless-aws/src/util/Util_StaticBundle.res`. Returns `array<{relativePath, absolutePath, fileAsset, contentHash}>` (entry shape extended beyond the original plan so the caller can wire `etag` directly without re-reading files). The walker:
- Uses Node's `fs.readdirSync` with `{withFileTypes: true}` and recurses manually (matches the local pattern in `Util_Bundle.res`; the global `recursive: true` flag is not needed since we already need to recurse to push hash entries).
- Skips dotfiles by default (covers `.DS_Store`; source maps remain a future flag — out of scope here).
- Returns paths normalised to forward-slash relative-to-`assetsDir` form (S3 keys never contain backslashes).
- Reads file bytes once during the walk to compute a SHA-256 hex digest; `Plugin_Stack` reuses that digest as the `BucketObject.etag` so Pulumi diffs only changed files (covers section 1.3 inline).

A new `S3.BucketObject` binding was added to `rescript-pulumi-aws` (`src/S3/S3_BucketObject.res`, exported via `S3.res`) since none existed.

`makeUiBundleDistribution` then iterates and creates one `PulumiAws.S3.BucketObject` per entry. The Pulumi resource name needs to be deterministic and unique:

```rescript
let _ = PulumiAws.S3.BucketObject.make(
  ~name=name ++ "-asset-" ++ Util_StaticBundle.sanitizeName(relativePath),
  ~args={
    bucket: bucket.id->Pulumi.Output.asInput,
    key: Pulumi.Input.make(relativePath),
    source: Pulumi.Input.make(fileAsset),
    contentType: Pulumi.Input.make(Util_StaticBundle.contentTypeFor(relativePath)),
  },
)
```

`sanitizeName` replaces `/` and `.` with `-` so Pulumi resource URNs stay valid. `contentTypeFor` returns the correct MIME by extension; falls back to `application/octet-stream` for unknown extensions and logs a warning so missing types surface in the deploy log.

### 1.3 Asset hash → cache busting

Done as part of 1.2: the walker reads each file once and emits its SHA-256 hex digest in `entry.contentHash`. `Plugin_Stack` passes that string as `BucketObject.etag`, so Pulumi diffs against the prior etag and re-uploads only files that actually changed. We use Crypto directly (matching the `Util_Bundle.res` precedent) rather than relying on Pulumi's per-asset hash output, since this keeps the value available synchronously at deploy-graph construction time.

### 1.4 Validation

- ✅ Unit test (`tests/Util_StaticBundleTest.res`): `contentTypeFor` returns the expected MIME for html, css, js, mjs, json, svg, woff2, wasm, uppercase extensions, and unknown→`application/octet-stream`.
- ✅ Unit test: `sanitizeName` replaces `/` and `.` with `-` (covers Pulumi URN safety).
- ✅ Unit test: `walk` of a tmp fixture returns the expected forward-slash relative paths, skips dotfiles (`.DS_Store`), produces non-empty content hashes, and is deterministic + content-sensitive (same bytes → same hash; different bytes → different hash). Also covers the missing-directory throw path.
- ⏳ Integration: deploy with a real bundle and confirm S3 `ListObjectsV2` + the right content types — pending an AWS environment to deploy into.

---

## Phase 2 — SPA history fallback + index document  ✅ Done

### 2.1 Add `customErrorResponses` when `~spaFallback=true`

Extend the existing `Distribution.make` call at [Plugin_Stack.res:36-69](../../reventless/reventless-aws/src/Plugin_Stack.res#L36-L69) to include:

```rescript
customErrorResponses: spaFallback
  ? Pulumi.Input.make([
      {
        PulumiAws.CloudFront.Distribution.errorCode: 403,
        responseCode: 200,
        responsePagePath: "/" ++ indexDocument,
        errorCachingMinTtl: 0,
      },
      {
        errorCode: 404,
        responseCode: 200,
        responsePagePath: "/" ++ indexDocument,
        errorCachingMinTtl: 0,
      },
    ])
  : Pulumi.Input.make([]),
```

`errorCachingMinTtl: 0` is intentional: under SPA fallback, errors are not really errors, so don't pin them in the edge cache.

**Why 403 *and* 404.** S3 returns 403 (not 404) for missing keys when the bucket policy denies `ListBucket`. Most SPA bundles deployed via OAC end up with the 403 path. Catching both is standard practice.

The `customErrorResponse` type and the optional `customErrorResponses` field were added to `rescript-pulumi-aws/src/CloudFront/CloudFront_Distribution.res`. `Plugin_Stack` always passes an array — empty when `~spaFallback=false`, two entries (403 and 404) when `~spaFallback=true`.

### 2.2 Set `defaultRootObject`

Done. The CloudFront binding already exposed `defaultRootObject?: Pulumi.Input.t<string>` from a previous change, so `Plugin_Stack` simply wires `Pulumi.Input.make(indexDocument)` into the distribution args (always set, not gated on `~spaFallback`, since the bare distribution URL should resolve regardless).

### 2.3 Validation

- ⏳ Integration with `~spaFallback=true`: hit `${distributionUrl}/`, `/index.html`, and `/foo/bar/baz`; expect 200 + bundle HTML on all three. Pending AWS deploy.
- ⏳ Integration with `~spaFallback=false`: hit `/foo/bar/baz`; expect 403/404. Pending AWS deploy.

---

## Phase 3 — Backwards compatibility + migration  ✅ Done (code), ⏳ pending integration

### 3.1 Keep the old shape working

Existing callers that pass only `~pluginId` and `~bundleVersion` continue to work — they get a distribution with no `BucketObject` uploads and no `customErrorResponses`. The new arguments are all optional with safe defaults.

Note: `defaultRootObject` is now always set to `indexDocument` (defaults to `"index.html"`) even for legacy callers. This is a deliberate behaviour change vs. pre-plan — without it, the bare distribution URL returns 403 on every empty distribution, which is never useful. If a caller actually relied on the prior 403, they can opt out by passing `~indexDocument=""` (CloudFront treats empty string as unset). Worth flagging in the changelog.

### 3.2 Document the recommended call site

Done. The doc-comment on `Plugin_Stack.makeUiBundleDistribution` shows the SPA call form and notes that the bundle must be built before `pulumi up`.

The helper fails fast in two cases: if `~assetsDir` is supplied but does not exist (raised by `Util_StaticBundle.walk` with the missing path in the message), and if `~assetsDir` exists but contains zero files after dotfile filtering (raised in `Plugin_Stack` with the offending path).

### 3.3 Validation

- ⏳ Integration with no `~assetsDir`: confirm the resource graph matches pre-plan output. Pending AWS environment + recorded snapshot.
- ✅ Code-level: a non-existent `~assetsDir` raises with a message naming the missing path (covered by `walk`'s "throws when assetsDir does not exist" unit test); an empty directory raises in `Plugin_Stack` before any `BucketObject` is created.

---

## Out of scope

- **Custom domain + ACM certificate.** Distribution-level config for `aliases` and `viewerCertificate.acmCertificateArn`. Future helper, separate plan — independent of asset upload and SPA fallback.
- **Cache-control headers.** Per-file `Cache-Control` (e.g. `max-age=31536000, immutable` for hashed assets, `no-cache` for `index.html`). The default `CachingOptimized` policy already handles most of this at the edge; per-object headers are a tuning step.
- **Origin behaviours for non-bundle paths.** If a deployment wants the distribution to also serve `/api/*` from a different origin, that's a multi-origin distribution and belongs in a separate helper (`makeMultiOriginDistribution`). The current helper is single-origin by design.
- **Source map handling.** Whether to upload `.map` files is deploy-policy. Out of scope; callers can `rm dist/**/*.map` before calling if they want to exclude them.
- **CloudFront invalidation on deploy.** Pulumi's content-hashed `BucketObject` etag triggers updates; the `CachingOptimized` policy honours `ETag` validators, so clients fetch fresh content on the next request without an explicit `CreateInvalidation` call. If hard cache busting is later needed, add `~invalidateOnDeploy: bool` in a follow-up.

---

## Validation — full plan

- ✅ Existing callers that don't supply the new args still compile and the helper still produces the same bucket / OAC / distribution / bucket-policy resources (only the always-set `defaultRootObject` is new — see 3.1).
- ⏳ A deploy with `~assetsDir + ~spaFallback=true` results in a live URL where: the root serves `index.html`, deep client-side routes serve `index.html` (200), and JS/CSS load with correct MIME types. *Pending AWS deploy.*
- ⏳ Re-running `pulumi up` with no source changes is a no-op (no `BucketObject` updates). *Pending AWS deploy.*
- ⏳ Editing a single file in `~assetsDir` and re-running `pulumi up` updates only that one `BucketObject`. *Pending AWS deploy — but the etag is content-derived, so the diff will be limited to changed files by construction.*

## What landed

- `rescript/rescript-pulumi-aws/src/S3/S3_BucketObject.res` (new) — binding for `aws.s3.BucketObject`. Re-exported from `S3.res` as `S3.BucketObject`.
- `rescript/rescript-pulumi-aws/src/CloudFront/CloudFront_Distribution.res` — added `customErrorResponse` type and `customErrorResponses?: Pulumi.Input.t<array<customErrorResponse>>` arg. (`defaultRootObject` was already present.)
- `reventless/reventless-aws/src/util/Util_StaticBundle.res` (new) — `walk(assetsDir)`, `contentTypeFor(path)`, `sanitizeName(path)`. Hashes file bytes (SHA-256 hex) for cache-busting etag. Re-exported from `util/Util.res` as `Util.StaticBundle`.
- `reventless/reventless-aws/src/Plugin_Stack.res` — extended `makeUiBundleDistribution` with `~assetsDir`, `~spaFallback`, `~indexDocument`. Wires per-file `BucketObject` upload, SPA `customErrorResponses`, and always-on `defaultRootObject`. Doc comment shows the recommended SPA call form.
- `reventless/reventless-aws/tests/Util_StaticBundleTest.res` (new) — 18 unit tests covering all three helper functions (see 1.4 for the matrix).

## Open follow-ups

- Integration validation against a real AWS deploy (the ⏳ items above).
- Optional: `~invalidateOnDeploy: bool` if hard cache busting is ever needed (mentioned under "Out of scope").
- Optional: `~excludeSourceMaps: bool` flag in `Util_StaticBundle.walk` (mentioned under "Out of scope").

## Commit message

`feat(aws): makeUiBundleDistribution uploads assets and supports SPA history fallback`
