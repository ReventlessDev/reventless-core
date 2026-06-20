# Harden deploy-time AppSync schema push against concurrent-stack clobber

**Date:** 2026-06-21

**Status:** Implemented + build-verified on `alpha` (`rescript build` clean;
`GraphQL_StitcherTest` green). Concurrent multi-stack deploy verification still
pending — re-confirm a parallel redeploy of several plugin/service stacks lands
every stack's fields and that a stale stitch logs `ABORTED` rather than pushing.

**Relates to:**
[appsync-runtime-schema-clobber-hardening.md](appsync-runtime-schema-clobber-hardening.md)
— the *runtime* counterpart. This plan ports that plan's shrink-guard circuit
breaker to the **deploy-time** push, which never got it.

---

## Problem

Multiple plugin/service stacks all publish into **one shared AppSync API**. Each
stack's deploy runs `preResolversSchemaHook`
(`reventless/reventless-aws/src/Platform.res:664`):

1. Write this plugin's SDL fragment as a `deploy-schema:<name>` row.
2. **Scan all** `deploy-schema:*` rows.
3. Stitch base + all scanned fragments → one SDL.
4. If the SDL hash differs from the last-pushed hash, **push** via
   `StartSchemaCreation` — which **replaces the entire schema**.

The scan→stitch→push sequence is **not atomic and not locked across stacks**, and
the push has **no shrink guard**. So a concurrent peer that scans *before* this
stack writes its row stitches an SDL missing this stack's fields, and — because
its hash differs — pushes it, replacing the live schema and **dropping every
field it didn't see**. The orphaned fields' resolvers (created through the
retrying dynamic provider) then poll for ~150 s and fail with:

```
pulumi-nodejs:dynamic:Resource (<Plugin>_<Field>):
  error: No field named <Plugin>_<Field> found on type Query
```

`startSchemaCreationRetrying` only serialises push *timing* (it retries
`ConcurrentModificationException`); it does nothing about the stale *content*.
Last writer wins, and if the last writer scanned stale, fields vanish.

### Why the existing checks don't catch it

`preResolversSchemaHook` already introspects the live schema — but only inside
the **hash-match** branch, as a *repair* trigger (force a re-push when the live
schema drifted below what we last pushed, `Platform.res:886-911`). On a **hash
mismatch** (exactly the stale-stitch case) it pushes unconditionally with no
introspection and no shrink check.

The **runtime** path already solved the identical risk: `mkUpdateApiSchema`
(`AdminEventCollectorEntryPoint.mjs:524-535`) introspects live and calls
`isCatastrophicSchemaShrink(currentSdl, sdl, threshold)`, aborting the push if
the new SDL drops below `threshold ×` the live root-field count. The deploy path
never got that guard.

## Fix

Port the runtime shrink guard to the deploy-time push. The helper already exists
and is shared: `ReventlessCore.GraphQL_Stitcher.isCatastrophicSchemaShrink`.

In `preResolversSchemaHook`, before `startSchemaCreationRetrying`:

- Introspect the live schema once (reuse it for both the existing drift check and
  the new guard).
- If `isCatastrophicSchemaShrink(~currentSdl=liveSdl, ~newSdl=sdl, ~threshold)` is
  true, **abort the push** (log at error), leaving the live schema intact.
- Otherwise push as before.

Behaviour by case (root-field counts, `threshold` default 0.5):

| Scenario | live vs new | Action |
|---|---|---|
| Stale concurrent scan (missing peer fields) | new ≪ live | **abort** — no clobber |
| Legit new fields (own row included) | new ≥ live | push |
| Hash-match repair (live drifted down) | new ≥ live | push (not a shrink) |
| First deploy / introspection empty | live = 0 | push (helper returns false) |

A stale stack thus **refuses to clobber**; the field-owner's own deploy — whose
scan includes its freshly-written row — pushes the complete set. This mirrors the
runtime guard exactly, so the two push paths now share one invariant: *never
replace the live schema with a catastrophically smaller stitch.*

Threshold: new module-level constant in `Platform.res`, default `0.5`, override
via `DEPLOY_SCHEMA_SHRINK_THRESHOLD` (values outside `(0, 1)` fall back) — the
deploy-time analogue of the runtime `RUNTIME_SCHEMA_SHRINK_THRESHOLD`.

## Limitations / follow-up

The guard is **defense-in-depth**, not a coordination primitive. It prevents the
clobber but does not *land* a stale stack's legitimate new fields in that run —
the owner's own deploy does. Under pathological interleaving a stack could be
refused repeatedly; in practice each stack's own deploy always stitches its own
row (written in step 1, same invocation) so its push is never a self-shrink.

The fully-robust fix is a **distributed lock** around scan→stitch→push (e.g. a
conditional-write lease row in the PluginSchemaPersistence table) so pushes are
serialised on *content*, not just timing. That is larger and deferred; the
shrink guard removes the data-loss symptom with a few lines and an existing,
tested helper.

## Acceptance

- Concurrent redeploy of several plugin/service stacks leaves every stack's
  fields present in the live schema; no `No field named …` resolver failures.
- A deliberately-stale stitch logs `ABORTED schema push … refusing to clobber`
  and does **not** call `StartSchemaCreation`.
- First deploy (empty live schema) still pushes.

## Files

- `reventless/reventless-aws/src/Platform.res` — `preResolversSchemaHook`: add
  the shrink guard around the push; add the `DEPLOY_SCHEMA_SHRINK_THRESHOLD`
  constant.
