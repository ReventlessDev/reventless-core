# Plan: the online-shop-dcb AWS plugin stacks get their generated entry points

**Date:** 2026-10-07<br/>
**Status:** Backlog — extracted from [../done/declared-object-stores-without-host-ui-bundle.md](../done/declared-object-stores-without-host-ui-bundle.md) when it closed. Latent rather than broken: no workflow deploys `online-shop-dcb`, so nothing fails today. It fails on the first `pulumi up` of either plugin stack.<br/>
**Relates to:** the same gap, already fixed for `online-shop-aggregates`, recorded in the parent plan's *Still to do*.

---

## In plain words

A plugin's AWS stack (`<plugin>-aws`) runs Pulumi against `src/Main.res.mjs`, which imports a
generated composition root, `src/Plugin.res` (written by `generate-plugin` in the package's
`prebuild`). The root `pnpm run build` chain does **not** build `*-aws` plugin packages — only
`platform-aws` and `platform-local` — so those files exist only if they are committed.

## What is left

On 2026-10-07 the tracked files are:

| Package | Tracked under `src/` |
|---|---|
| `examples/online-shop-dcb/catalog-aws` | `Main.res` only |
| `examples/online-shop-dcb/ordering-aws` | `Main.res` only |
| `examples/online-shop-aggregates/*-aws` (for comparison) | `Main.res`, `Main.res.mjs`, `Plugin.res`, `Plugin.res.mjs` |

A deploy of either `online-shop-dcb` plugin stack would fail exactly as the aggregates stacks did:
`project 'main' could not be read: … src/Main.res.mjs: no such file or directory`.

## What done looks like

1. Run each package's own `pnpm run build` (its `prebuild` runs `generate-plugin`), and commit
   `Plugin.res`, `Plugin.res.mjs` and `Main.res.mjs` for both packages.
2. Confirm `pnpm run check:fresh-outputs` treats them like the other tracked deploy outputs, so a
   later framework change cannot leave them stale unnoticed. If it cannot reach them because the root
   build skips `*-aws` plugin roots, say so here and decide whether a build step is worth adding.
