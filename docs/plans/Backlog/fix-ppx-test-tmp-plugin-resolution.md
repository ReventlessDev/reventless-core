# Fix reventless-ppx integration test: `/tmp` plugin can't resolve `sury`

Status: **Backlog.** Pre-existing failure (red in every `publish-ppx.yml` run since
at least 2026-06-14). **Non-blocking** — `publish-main` is independent of the
`Test PPX` job, so per-platform + main publishes succeed despite the red ✗. Only
cost: the overall workflow run shows failure even on a successful publish, so
publish success must be verified against the registry directly, not the run status.

## Symptom

`packages/reventless-ppx/test/run.sh` fails at the first fixture:

```
Building PPX...
Compiling plugin package...
[1/2] ❌ Error building package tree. try_package_path: upward traversal did not
find 'sury' starting at '/tmp/tmp.XXXXXX'
ERROR: Could not build package tree reading dependency 'sury' ... Plugin build FAILED
```

## Root cause

The harness builds a throwaway ReScript plugin in `mktemp -d` (`/tmp/tmp.XXX/plugin`)
and symlinks the repo's `node_modules` into it:

```sh
ln -s "$REPO_ROOT/node_modules" "$PLUGIN/node_modules"   # test/run.sh:64
```

ReScript v12's package-tree resolver does **upward directory traversal** for
declared dependencies (`"dependencies": ["sury", "@reventlessdev/reventless-spec"]`)
and starts from `/tmp/tmp.XXX` — which has no `node_modules` up its ancestry — so it
never reaches the symlinked tree the way the test assumes. Same family as the known
"rescript rejects deps outside the node_modules tree" resolution issue. Likely broke
on a rescript-v12 / pnpm-layout change, **not** the npmjs registry migration.

## Fix direction (validate with a real ppx + rescript build)

Relocate the temp plugin **inside the workspace tree** so upward traversal reaches
the real hoisted `node_modules`, instead of `/tmp`. Options:

- Create the fixture under e.g. `packages/reventless-ppx/.test-tmp/<rand>/plugin`
  (gitignored) and `trap`-clean it — upward traversal then finds
  `<repo>/node_modules`.
- Or copy/junction `sury` (+ `sury-ppx`, `@reventlessdev/reventless-spec`) into the
  temp plugin's own `node_modules` rather than symlinking the whole root.

Must be validated by running `./test/run.sh` with a locally-built ppx (the OCaml
toolchain), since the failure is in rescript's resolver, not the shell logic.

## Not in scope

The publishing pipeline itself — `publish-ppx.yml` per-platform + main publishing is
correct and unaffected by this test.
