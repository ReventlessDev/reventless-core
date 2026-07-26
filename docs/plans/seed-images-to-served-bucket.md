# Plan: Seed real image objects into the served bucket (local + AWS)

**Date:** 2026-07-26
**Repo:** reventless-core (seed toolkit + example seed)
**Depends on:** [served-buckets.md](done/served-buckets.md) — the served-bucket
read path (AWS CloudFront `{prefix}/*` + the local dev-server serve route) and a
unified upload contract must exist for seeded objects to be viewable.
**Status:** NOT STARTED (plan only)

## Problem

The example seed sets each product's `imageUrl` to an **external** URL —
`https://picsum.photos/id/<n>/400/300`
([DemoData.res:130](../../examples/online-shop-hybrid/platform-local/src/DemoData.res#L130)).
Those URLs:

- **bypass the bucket and the CDN entirely** — the browser fetches them straight
  from picsum, so the seed never exercises the upload → store → serve loop the
  served-bucket work builds;
- **depend on a third-party service** being reachable at render time;
- make the demo **inconsistent** with how a real product image arrives (a user
  upload that lands in the bucket).

We want seed products to reference objects that actually live **in the served
bucket**, uploaded at seed time — and, per the served-bucket design, this must
work for both **local dev** and **AWS**.

## Decision

The seed is already a standalone GraphQL client that drives the example's public
API ([DemoSeed.res](../../examples/online-shop-hybrid/platform-local/src/DemoSeed.res),
`ReventlessSeed`), endpoint-agnostic via `REVENTLESS_GRAPHQL_ENDPOINT` (local by
default, retargetable at a deployed AWS API). So:

- **Upload through the same contract the browser uses.** The seed uploads each
  product image via the deployment's **upload endpoint** (`config.uploadEndpoint`
  — the presign-shaped `POST {fileName,contentType} → {uploadUrl, storageRef}`,
  then `PUT`), then sets `imageUrl` to the returned same-origin `/{prefix}/{key}`
  ref. This is **provider-neutral for free** (local upload route vs. AWS presign
  Function URL) and turns the seed into a fuller smoke test of the upload path.
- **Image bytes are self-contained and deterministic** — generated SVG
  placeholders (a distinct color + the product name), so no repo binaries and no
  network dependency; bundled real images are an alternative if photographic
  content is wanted.
- **Retire the picsum pool.**

The seed never needs direct bucket/store access or provider credentials for
storage — it goes through the upload endpoint exactly like the UI, so the same
code path serves local and AWS.

## Part 1 — Unify the upload contract across providers (prerequisite refinement)

For one seed helper (and one UI adapter) to cover both providers, the **local**
upload route must expose the **same presign-shaped contract** as AWS
([Upload_Presign_S3](../../reventless/aws/src/adapter/Upload/Upload_Presign_S3.res)):
`POST {fileName,contentType} → {uploadUrl, storageRef}`, then a `PUT` of the
bytes to `uploadUrl` (a local URL), storing under `{prefix}/{key}` and returning
`storageRef = "/{prefix}/{key}"`.

- This tightens [served-buckets.md](done/served-buckets.md) Part 2b: implement the
  local upload route in the presign shape (return a local `uploadUrl`) rather than
  a bespoke direct-`POST`, so the reventless-ui `FileDropzone` S3 upload adapter
  and the seed helper below are one code path for both.
- Local `uploadUrl` may just be a same-origin `PUT /{prefix}/{key}` the dev
  route accepts; no signing needed. The contract shape — not the signing — is
  what unifies the providers.

## Part 2 — Seed-time upload helper (ReventlessSeed)

Add an upload capability to the seed toolkit
([reventless/seed](../../reventless/seed/src)), alongside `Seed.Client` /
`Seed.Runner`:

```rescript
// Seed.Upload
let uploadAsset = (
  ~uploadEndpoint: string,
  ~bytes: /* Uint8Array | string */,
  ~fileName: string,
  ~contentType: string,
  ~authToken: option<string>=?,
): promise<result<string, string>>   // Ok(servedRef e.g. "/uploads/<key>")
```

- Implements the contract from Part 1: `POST` the presign request (bearer when
  present), then `PUT` the bytes to `uploadUrl`, resolve `Ok(storageRef)`.
- The upload endpoint is discovered like the GraphQL one — a
  `REVENTLESS_UPLOAD_ENDPOINT` env (default the local route, e.g.
  `http://localhost:4000/uploads/presign`), or read from the target's
  `config.json`. Mirrors `Seed.Runner.envOr` usage in DemoSeed.
- Node-side `fetch`/`PUT` (the seed runs under Node); reuse the seed client's
  auth/token if the endpoint requires it.

## Part 3 — Image source (deterministic, self-contained)

Generate a **placeholder SVG per product** — a distinct fill color (deterministic
from the product index) plus the product name as a label — and upload it with
`contentType = "image/svg+xml"`. SVG renders in `<img src>`, serves cleanly
through CloudFront / the local route, is tiny, text-based (no repo binaries), and
fully deterministic. (Alternative: bundle a small pool of real `*.jpg` files
under `platform-local/seed-assets/products/` and upload those bytes — choose this
only if photographic content matters.)

## Part 4 — Seed wiring

In [DemoData.res](../../examples/online-shop-hybrid/platform-local/src/DemoData.res) /
[DemoSeed.res](../../examples/online-shop-hybrid/platform-local/src/DemoSeed.res) /
[DemoCommands.res](../../examples/online-shop-hybrid/platform-local/src/DemoCommands.res):

1. Remove the `productImages` picsum pool + `productImageFor`
   ([DemoData.res:130-142](../../examples/online-shop-hybrid/platform-local/src/DemoData.res#L130)).
2. For each product, **before** sending `AddProduct`: generate its SVG, call
   `Seed.Upload.uploadAsset(...)`, and use the returned `/{prefix}/{key}` as the
   product's `imageUrl`. `ChangeProductImage` demo edits (if any) upload a fresh
   asset the same way.
3. Keep it deterministic (fixed `0x5eed` RNG for colors; no `Math.random`/
   `Date.now`). The upload runs sequentially per product (or a bounded
   `Promise.all`), then the `AddProduct` mutation carries the served ref.

Idempotency note: the presign contract mints a fresh `uuid` key per upload, so
re-seeding produces new objects (old ones are orphaned until the bucket/store is
reset). If idempotent seeding matters, extend the upload contract with an
optional caller-supplied key (`{key?}`) and have the seed use a stable
`seed/products/<productId>` key; otherwise accept fresh keys on each `serve:reset`.

## Acceptance

- After `pnpm run demo-data`, each product's `imageUrl` is a `/{prefix}/{key}`
  ref and the image **renders in the browser served from the bucket** — local via
  the dev serve route from the local store; AWS via CloudFront from the private
  S3 bucket. No picsum, no external image dependency.
- The same seed run works against a **local** endpoint and an **AWS** endpoint by
  pointing `REVENTLESS_GRAPHQL_ENDPOINT` + `REVENTLESS_UPLOAD_ENDPOINT` at the
  target — one code path, both providers.
- Re-running after `serve:reset` yields a coherent dataset; the seed exercises the
  real upload path (fuller smoke test).
- Example builds and GWT stay green; the seed toolkit change compiles.

## Notes

- **Provider-neutrality is free** because the seed uploads via the same endpoint
  the UI does — no seed-side S3/credential handling, no per-provider branch.
- **Sequencing:** land [served-buckets.md](done/served-buckets.md) first (both
  read paths + the unified upload contract, Part 1 here), then this.
- **No repo binaries** with the SVG approach; deterministic and self-contained.
- This closes the loop the picsum URLs skipped: an image now travels
  upload → bucket → (CloudFront | local route) → `<img>`, exactly like a real
  user upload, in the demo data itself.
