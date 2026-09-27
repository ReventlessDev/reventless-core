# Plan (Backlog): the lifecycle harvest outside the monorepo, and placement for a view with no lifecycle

**Status:** Backlog. §1 built 2026-09-27; §2 not started.

**Relates to:** [lifecycle-transition-annotation](../lifecycle-transition-annotation.md),
[lifecycle-fact-provenance](../lifecycle-fact-provenance.md)

---

## 1. `check-lifecycle` says why it cannot build

`CheckLifecycleModel.emitSidecars` runs `pnpm run build` at `--root` with
`REVENTLESS_EMIT_SIDECAR=1`. In this repo the root has a `build` script. In an app laid out as
one package per plugin plus a platform package, the root has none, and the run ends with only
`Command failed: pnpm run build`. The harvest works there with `--reuse-sidecars` after the
packages were built with the variable set, but nothing says so.

**Change:** when the root has no `build` script, stop before running anything and say what to
do instead: build the packages with `REVENTLESS_EMIT_SIDECAR=1`, then run with
`--reuse-sidecars`. The same sentence when the build runs and fails, with the build's own last
lines after it.

**Verify:** in an app whose root has no `build`, plain `check-lifecycle --update` exits
non-zero with that sentence; with the sidecars built, `--reuse-sidecars` harvests as today.

## 2. A view with no lifecycle field still places its commands by their scenarios

The harvest labels a history with the states of a linked view's lifecycle field. A view with
no lifecycle field (a plain list of drivers, say) gives no labels, so its commands harvest with
level `""`, and placement falls back to `Plugin_Structure.isCreateCommandName`, a guess from
the command's first word. `RegisterDriver` lands as the list's **+** button only because
"Register" is in that list; "Enrol a driver" would land in a row menu, where no row exists yet
to open it.

**Change:** a command whose every success starts from no row of its view is Collection-level,
whether or not the view declares states: the scenarios already say it (no row before, one
after). The first-word guess stays for a plugin with no scenario corpus at all.

**Verify:** a list view without a lifecycle field, with one command named `EnrolDriver` whose
scenarios start from an empty history, harvests as Collection-level.
