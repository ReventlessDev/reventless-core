# Plan: consolidate the `rescript/` bindings

**Date:** 2026-07-30
**Status:** Open.
**Repos:** `reventless-core` only.
**Prompted by:** [generate-platform-beyond-the-example-topology.md](./done/generate-platform-beyond-the-example-topology.md),
which added a *fourth* inline set of `node:fs`/`node:path` externals and made F2 below visible.

## Why now rather than later

The framework is in alpha. Every change in this plan — merging a published package, relocating one,
changing a declared license — is one whose cost is paid by consumers, and there are none yet outside
the repositories this project already controls. Renaming or removing a published package after the
first external consumer pins it inverts the argument permanently: the fragmentation gets kept for
compatibility rather than for a reason.

This is a set of packaging decisions with a closing window, not improvements that get cheaper by
waiting.

## Three findings

### F1. Two packages that are not independently useful

`rescript-node-zlib` **already depends on** `rescript-node-streams` — its compression bindings are
typed in terms of `NodeStreams.Readable.t`. They are one binding surface published as two artifacts,
each with its own version, changelog and release. Nothing consumes zlib without streams.

### F2. The same builtins bound repeatedly, and inconsistently

49 `.res` files bind a node builtin, across **three competing de-facto bindings modules** —
`Generator_Node` (spec), `layer-builder/src/bindings/{NodeFs,NodePath}`, and a growing set of inline
blocks (`LocalHost`, `PackageVersion`, `EmitCapabilities`, `SqliteDriver`, `UserStore`, the seed
packages, …). The duplication is cheap; the **drift** is not:

| Binding | Spellings in the tree today |
|---|---|
| `existsSync` | 6 — three `@module("node:fs")`, three `@module("fs")` |
| `join` | 3 incompatible signatures — `(string, string)`, `@variadic array<string>`, bare `@module("path")` |
| `readFileSync` | 2 — `(string, string) => string` vs `(string, @as("utf8") _) => string` |
| `dirname` | 4 |

A second `join` taking two arguments is not a duplicate of a variadic one — it is a different
function with the same name, and which one a file gets depends on which block it happens to sit near.

### F3. Four packages with no consumer in this repository

`rescript-anthropic`, `rescript-pulumi-kubernetes`, `rescript-pulumi-docker-build` and
`rescript-moment` are depended on by no `package.json` and no `rescript.json` in this tree, and no
`.res` file here imports their modules. Each is consumed by exactly one downstream repository.

They are not dead — they do what they were built for. They are simply in the wrong repository: this
one installs their npm dependencies (~30 MB) on every contributor's machine and compiles against none
of them.

## Decisions

### D1. One binding package, `@reventlessdev/rescript-node` at `rescript/node`, `namespace: false`

Both merged packages are already `namespace: false`, so their modules are globally `NodeStreams` and
`NodeZlib`. **Keeping that means the merge does not touch a single call site**, and the migration for
the dependents is a dependency swap in `package.json` + `rescript.json`. That is why step 1 is small
enough to go first.

### D2. Canonical signatures — this is the actual content of the change

Merging files is mechanical. Choosing one spelling per builtin needs a decision and is the part that
pays:

- **`node:` prefix, always.** Bare `"fs"` is what bundlers alias to browser polyfill shims, and this
  repo bundles Lambda code archives (`Util_Bundle`, `buildCodeArchive`). `node:fs` is unambiguous to
  Node and to every bundler.
- **`join` / `resolve` are `@variadic array<string> => string`.** A strict superset of the two-argument
  form, so no call site loses expressiveness.
- **`readFileSync` is `(string, @as("utf8") _) => string`.** The encoding is baked in rather than
  passed, so it cannot be passed wrongly — the `(string, string)` form is the one that permits
  `readFileSync(path, "utf-8")`, a different string, silently.

Module split, one per builtin: `NodeFs`, `NodePath`, `NodeUrl`, `NodeProcess`, `NodeOs`,
`NodeCrypto`, `NodeChildProcess`, `NodeModule`, plus the moved `NodeStreams` and `NodeZlib`.

### D3. Zero dependencies, zero side effects at module scope

Non-negotiable — see the risks table. These bindings land inside Lambda runtime module graphs.

### D4. A binding belongs in the repository of its lowest common consumer

This repository is the right home for a binding **two or more** downstream repositories share: it is
their common upstream and it already publishes them. It is the wrong home for one that exactly one
repository consumes — that is ownership sitting apart from use, and it bills every contributor here
for an install nothing here compiles.

The relocation is **not a rename**: `@reventlessdev/` is an organisation scope, not a repository
scope, so a relocated package keeps its name and version line and consumers see nothing change. Only
the publishing repository moves.

### D5. One license across the bindings: Apache-2.0, stated per package

The repository root carries `LICENSE` and `NOTICE` and declares Apache-2.0, and all 18 `rescript/*`
packages declare `Apache-2.0` in `package.json`. One does not match its own declaration:
`rescript/moment` ships a **`LICENSE` file containing the MIT license with a blank copyright holder**
(`Copyright (c) 2017`), inherited from the `bs-moment` project it was derived from (`373db3463`,
"based on bs-moment").

That is a package distributing two contradictory sets of terms, and the file that would settle it
names no one. The fix is not to delete the file: a derivative may be distributed under Apache-2.0,
but only while the upstream notice is preserved. So the upstream MIT notice stays, with its holder
**identified**, and moves to where a preserved third-party notice belongs — `NOTICE` — leaving
`LICENSE` to state the terms the package is actually offered under.

**Every binding package that is a port or derivative of another project must carry that project's
notice, and must ship it.** A package whose `files` array excludes `LICENSE`/`NOTICE` does not
distribute the notice at all, whatever the repository contains.

## Steps

1. **Merge the two node packages, no call-site changes.** Create `rescript/node` with
   `NodeStreams.res` and `NodeZlib.res` moved verbatim; repoint the dependents; delete
   `rescript/node-streams` and `rescript/node-zlib`.
   **Verify:** full build clean and root suite green with **no `.res` file edited outside the moved
   two** — the diff should be package manifests plus two file moves.

2. **Add the fs/path/url/process modules with D2's signatures, and retire the two de-facto modules.**
   Migrate `Generator_Node` and delete `layer-builder/src/bindings/{NodeFs,NodePath}`.
   **Note the collision this resolves:** `layer-builder` is itself `namespace: false` and defines its
   own `NodeFs`/`NodePath`, which would clash with the shared ones — they must go in the same commit,
   not coexist.
   **Verify:** `generate-platform` and `generate-plugin` produce byte-identical output on all three
   examples; layer-builder builds.

3. **Migrate the inline binding sites, one package per commit.** ~45 files across `aws`, `local`,
   `gwt`, `seed`, `seed-aws`, `core`, `spec`. Per-package commits because a single 45-file diff is
   unreviewable and because `aws` needs the runtime check below.
   **Verify per package:** build clean, tests green; for `aws`, that the entry points still reference
   nothing but node builtins.

4. **Expose the release pipeline as a reusable workflow.** `release.yml` becomes a thin caller of a
   `workflow_call` workflow in `.github/workflows/`, parameterising what is specific to this
   repository: the `--ignore-changes` list, the PPX fallback build, the documentation changelog step
   and the workspace-setup script. This repository is public, so the workflow is callable by a
   repository receiving a package in step 5 without reproducing the pipeline.
   **Verify:** a release of this repository through the extracted workflow is indistinguishable from
   one before it. Callers pin a **tag**, never a branch — see the risks table.

5. **Relocate the four packages named in F3**, per D4. For each: the receiving repository takes over
   publishing, continuing the existing version line rather than restarting it; the package's tests are
   wired into that repository's test run; this repository drops the workspace member, the pnpm
   override where one exists, and the npm dependency.
   **Verify:** the next published version of each is a continuation of its predecessor and installs
   unchanged for existing consumers; a clean install here no longer fetches their npm dependencies.

6. **Settle the licensing per D5.** Give every binding package a `LICENSE`, give the derivative ones a
   `NOTICE` naming the upstream and its terms, and ensure both are inside each package's `files`
   array. Resolve `rescript/moment`'s contradiction first — it is the only one currently shipping
   terms that disagree with its own manifest.
   **Verify:** `npm pack --dry-run` on each package lists `LICENSE` (and `NOTICE` where it exists);
   no package declares one license and ships another.

7. **Deprecate the two merged npm names** (`npm deprecate` pointing at `rescript-node`) so a stale
   install explains itself rather than 404s.

## What this does not do

- **It does not merge unrelated small packages.** `rescript-uuid` (27 lines) and
  `rescript-hash-object` (22) are small because the libraries they bind are small, and they are
  genuinely shared here. Merging them buys a junk drawer and puts both npm dependencies on every
  consumer. Small is not the same as coupled.
- **It does not merge the Pulumi provider bindings into `rescript-pulumi-pulumi`.** That package has
  28 dependents here; `rescript-pulumi-aws` has 3, and `@pulumi/aws` is 58 MB. Merging would put that
  install on every package that only wants `Pulumi.Output.t`. The ReScript package boundary should
  keep mirroring the npm one.
- **It does not add convenience helpers to the bindings.** No `readJsonFile`, no path utilities. A
  convenience layer is what makes a bindings package impossible to keep dependency-free.
- **It does not change any binding's behaviour.** Every signature change in D2 is a widening or a
  constant fold. A call site needing more than a mechanical edit is a finding to record, not to fix
  in passing.

## Risks

| Risk | Mitigation |
|---|---|
| **The bindings package enters the Lambda runtime module graph** — `aws`'s `*_Ops` entry points bind `node:fs`/`node:crypto` directly, and those were made runtime-pure at real cost. A bindings package that pulls in a dependency reintroduces exactly that. | D3: zero dependencies, no module-scope side effects. Step 3 verifies the entry points after migration rather than assuming. |
| A `namespace: false` package collides with `layer-builder`'s own `NodeFs`/`NodePath`. | Step 2 deletes them in the same commit. The collision is the signal the consolidation is working. |
| **Unifying `readFileSync` silently changes an encoding** at a call site that passed something other than `"utf8"`. | Grep every `readFileSync` call for its second argument *before* migrating; any non-`"utf8"` caller keeps an explicit-encoding binding rather than being folded. |
| **A relocated package restarts its version line**, so a published version already exists and the release is rejected — or worse, a lower version is published and consumers' ranges silently stop resolving to it. | Step 5 verifies continuation explicitly. Record each package's current version before the move; the first release afterwards must be strictly greater. |
| **A relocated package's tests stop running** and its coverage goes dark without any signal. | This repository guards that with `scripts/check-jest-projects.mjs` (a declared project discovering 0 suites fails). Step 5 requires the equivalent guard on the receiving side before the move is considered done. |
| **A reusable workflow pinned to a branch** changes release behaviour in every calling repository the moment this one's branch moves — the same class of silent disagreement this repository's capability generation exists to remove. | Callers pin a tag; the tag moves deliberately. Never `@alpha`. |
| Relicensing a derivative drops an upstream notice that its license requires be preserved. | D5: the notice is preserved and the holder named, not deleted. Step 6 verifies through `npm pack`, since the repository containing a file and the package shipping it are different things. |
