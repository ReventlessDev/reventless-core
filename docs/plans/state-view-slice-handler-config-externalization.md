# Plan: Externalize StateViewSlice HANDLER_CONFIG out of the Lambda env var

**Date:** 2026-06-20

**Status:** Proposed — interim compression already shipped (uncommitted); durable
fix (this plan) not started.

**Relates to:**
[aws-platform-bundled-lambda-config-wiring.md](aws-platform-bundled-lambda-config-wiring.md)
(same "config outgrew the env var" shape, solved there for *static* plugin
definition by bundling a `pluginDefinition.json` asset — that approach does **not**
transfer here; see Background).

---

## Goal

Stop carrying the `AllStateViewSlices` Lambda's handler configuration in the
`HANDLER_CONFIG` environment variable, where it is bounded by AWS Lambda's **4 KB
total environment-variable limit**. Move it to an unbounded out-of-band store
(S3 object, or SSM advanced parameter) referenced by a small pointer env var, so a
plugin's StateViewSlice count can grow without ever hitting a serialization
ceiling.

This is a scaling-ceiling fix, not a feature: the consolidated-Lambda design is
correct, but it folds the entire slice set into one env var, which has a hard cap.

---

## Background — why this surfaced, and why the existing precedent doesn't transfer

### The failure

A plugin with 13 StateViewSlices failed at `CreateFunction`:

```
InvalidParameterValueException: Lambda was unable to configure your environment
variables because the environment variables you have provided exceeded the 4KB
limit. String measured: {"HANDLER_CONFIG":"{\"handlers\":[ ...13 entries... ]}", ...}
```

The builder
(`reventless/aws/src/adapter/Runtime/StateViewSliceRuntime_Builder_Single.res`)
consolidates *every* slice of a plugin into a single `AllStateViewSlices` Lambda
and serializes the full set into `HANDLER_CONFIG`. Each handler entry carries two
full module paths, a query-DB table name, and the (104-char) DynamoDB stream ARN.
At 13 slices the serialized block measured **4821 bytes** — over the 4096-byte cap.

### Why the bundle precedent does **not** apply

`aws-platform-bundled-lambda-config-wiring.md` solved the analogous overflow for
the plugin runtime by shipping `pluginDefinition.json` as a **bundled asset** read
from disk at cold start. That works there because `pluginDefinition` is **static**
— pure module paths and names, fully known at archive-build time.

The StateViewSlice handler config is **not** static: each entry's
`queryDbTableName` and `sourceUrn` are Pulumi **Outputs** (resolved only during
`pulumi up`, after the names/ARNs exist). Pulumi `AssetArchive` members must be
materialized before the Lambda resource is created, so an `Output<string>` cannot
be baked into the zip. The config must therefore live in a resource that *accepts*
an Output as its value — i.e. `aws.s3.BucketObject` or `aws.ssm.Parameter` — not
the code bundle.

---

## Interim mitigation already in place (compression)

To unblock the overflowing deploy immediately, `HANDLER_CONFIG` is now
emitted in a compact form that hoists the fields shared across a plugin's slices:

- a single top-level `base` (longest common module-path prefix) — entries store
  only the suffix;
- a single top-level `sourceUrn` (identical across a plugin's slices — same DCB
  stream) — per-entry `u` only when they differ;
- short keys `s` / `p` / `q` / `u`; a `"v":2` format tag.

`StateViewSliceEntryPoint.mjs` re-expands this to the full
`{specModule, projectionModule, queryDbTableName, sourceUrn}` shape (and still
accepts legacy full-key entries). Effect on the 13-slice case: **4821 → 1577
bytes**, headroom to ~35 slices.

This buys runway but does **not** remove the ceiling. A sufficiently large plugin
(or longer ARNs / table names) reintroduces the failure. This plan replaces it
with an unbounded store.

---

## Design — pointer env var + out-of-band config

### Store choice

| Option | Limit | Notes |
| --- | --- | --- |
| **S3 object** | effectively unbounded | one `BucketObject` per `AllStateViewSlices` Lambda; Lambda reads at cold start; needs `s3:GetObject` on that key |
| SSM advanced parameter | 8 KB | cheaper/simpler than S3 but still a (higher) cap; `ssm:GetParameter` |

**Recommendation: S3.** It removes the cap entirely (the whole point), and the
config is deploy-time data the Lambda already has IAM scope to reach. SSM-advanced
only raises the ceiling to 8 KB and reintroduces the same class of bug later.

### Builder changes (`StateViewSliceRuntime_Builder_Single.res`)

1. Keep the structured `handlerEntry` array (already introduced for compression).
2. In `buildLambda`, instead of (or in addition to, behind a size threshold)
   writing `HANDLER_CONFIG`, render the full config `Output<string>` and write it
   to an `aws.s3.BucketObject` (deterministic key, e.g.
   `state-view-slice-config/<lambdaName>.json`), parented to the Lambda's
   component.
3. Set env vars `HANDLER_CONFIG_BUCKET` + `HANDLER_CONFIG_KEY` (small, fixed size)
   in place of the inline blob.
4. Grant the Lambda role `s3:GetObject` on that object (reuse the existing role
   wiring used for query-DB tables).

A pragmatic variant: **keep inline `HANDLER_CONFIG` when it fits under a safe
threshold (e.g. 3 KB) and fall back to S3 only when it would overflow.** This
avoids an S3 round-trip at cold start for the common small-plugin case while
removing the ceiling for large ones. The entry point already distinguishes shapes
via the `v` tag; add a `"ref"` shape for the S3-pointer case.

### Entry point changes (`StateViewSliceEntryPoint.mjs`)

- If `HANDLER_CONFIG` is present, parse it as today (compact v2 or legacy).
- Else if `HANDLER_CONFIG_BUCKET`/`_KEY` are present, `GetObject` and parse the
  same compact schema.
- Reuse the existing `expandHandlers()` so downstream handler construction is
  unchanged regardless of source.

---

## Acceptance

- A 13-slice plugin deploys; add a regression fixture with enough synthetic
  slices that the *uncompressed* config exceeds 4 KB, proving the S3 path engages
  and the Lambda boots.
- Cold-start handler map is identical across inline and S3 sources.
- No change for small plugins that stay inline (no new S3 object, no extra IAM)
  if the threshold variant is chosen.

## Out of scope

- Sharding `AllStateViewSlices` into multiple Lambdas (defeats the consolidation
  design; not needed once config is unbounded).
- Touching any consuming plugin. A large slice count is only what first surfaces
  this; the fix is entirely in `reventless-aws`.

---

## Files

- `reventless/aws/src/adapter/Runtime/StateViewSliceRuntime_Builder_Single.res`
  — write config to S3, emit pointer env vars, grant `s3:GetObject`.
- `reventless/aws/src/adapter/Runtime/StateViewSliceEntryPoint.mjs`
  — fetch-from-S3 fallback ahead of `expandHandlers()`.
