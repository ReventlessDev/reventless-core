# Plan: each deploy job builds only its stack

**Date:** 2026-11-11<br/>
**Status:** ✅ Done 2026-11-11. [B1](#b1-resolve-the-stacks-path-before-the-build) to
[B3](#b3-an-input-that-says-how-a-plugin-job-builds) built, and
[B4](#b4-measure-on-a-real-caller) measured on a caller's first deploy with the input set.<br/>
**Touches:** `.github/workflows/deploy-reventless-aws.yml` (the reusable deploy workflow): the
plugin matrix's `Build` step, and a new input.

## Goal

A deploy builds what each stack needs, not the whole repository once per job. The wait for a
deploy gets shorter, and so does the bill for it.

## Why

- **Every job builds everything.** The platform job and each job of the plugin matrix run
  `pnpm run build` at the repository root. A caller with eight stacks builds the whole
  repository eight times in one deploy.
- **It is most of the bill.** Measured on a caller with a platform and seven plugin stacks: the
  build took 3.5 to 4.5 minutes in each job, about 30 of the deploy's 66 billed minutes. On the
  largest stacks, Pulumi takes about as long again. On the small ones the build is most of the
  job.
- **Minutes are scarce for private callers.** A private repository on GitHub's free plan has
  2,000 Linux minutes a month and runs on two cores. At about 66 minutes per deploy, a busy week
  of deploys uses a quarter of the month.

## The steps, B1 to B4

B stands for *build*.

### B1: resolve the stack's path before the build

The plugin job read its stack's path from the manifest (`Resolve plugin path`) after `Build`.
It now runs before it, so the build can use the path.

### B2: what a stack-only build has to cover

A root `build` script can do more than build packages. On the measured caller it runs ReScript
over the whole workspace, builds a web bundle with Vite, builds several stacks that are not in the
root's dependencies, and regenerates manifests. A filter by package (`pnpm --filter`) cannot know
that, so the workflow does not guess. The caller says how a plugin job builds
([B3](#b3-an-input-that-says-how-a-plugin-job-builds)), and the platform job keeps the full build.

Checked on the measured caller, each plugin stack built with `rescript build` in its own folder
from a fresh clone:

- **ReScript 12 builds the stack's dependencies with it.** The ordering stack compiled 1,724
  modules in 18 seconds, against 64.5 seconds for the full build (10 cores; on CI's two cores
  the full build takes 3.5 to 4.5 minutes).
- **Nothing the deploy needs is missing.** Against a full build, the stack-only build lacked only
  test modules. Each of the six plugin stacks built, and its entry module bundled with every
  import resolved (`esbuild --bundle`, with `@pulumi/*` and `@aws-sdk/*` external).
- **The bake job builds nothing,** so it needs no change.

### B3: an input that says how a plugin job builds

`plugin-build-command` (string, default empty). Run from the repository root, with `{path}`
replaced by the plugin's stack path, for example `pnpm --dir {path} run build`. Empty runs
`pnpm run build` as before, so a caller that sets nothing deploys exactly as today.

### B4: measure on a real caller

Deploy a change that touches every stack, before and after, and compare billed minutes and the
time to the last stack. Keep the input set only if the deploys are just as green.

> **Measured 2026-11-11** on the caller of [Why](#why), two deploys that each touched all eight
> stacks, the second with `plugin-build-command: "pnpm --dir {path} run build"`. Both were green,
> and the bake after the second found every stack registered.
>
> | | Full build in every job | Plugin jobs build their stack |
> |---|---|---|
> | Time to the last stack | 35 min | 20 min |
> | Billed minutes, all jobs | about 66 | about 37 |
> | Build in a plugin job | 3.5 to 5.2 min | 42 to 78 s |
> | Build in the platform job | 3.8 min | 3.9 min |
>
> The platform job still builds everything, so it now sets the pace for the plugins that wait
> on it. A smaller platform build is the next saving, and needs the same care as
> [B2](#b2-what-a-stack-only-build-has-to-cover): the platform stack is the one that serves the
> web bundle.

## Considered and not chosen

- **Filter by package as the default.** It would change every caller's deploy at once, and is
  wrong for any caller whose root build does more than build packages
  ([B2](#b2-what-a-stack-only-build-has-to-cover)).
- **Build once, hand the output to every job.** One job builds and uploads the output as an
  artifact, and every deploy job downloads it. But the output of a ReScript workspace is spread
  over every package (`lib/`, `*.res.mjs` beside the sources). Uploading and downloading it on
  every job costs time and artifact storage, which the free plan also limits. Worth trying if
  stack-only builds save too little for callers whose stacks share most of the code.
