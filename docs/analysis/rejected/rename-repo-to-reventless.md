# Consideration: Rename Repository from `reventless-core` to `reventless`

**Status:** Considered and rejected (2026-02-26)

## Motivation

After the namespace swap (spec → `Reventless`, core → `ReventlessCore`), the question arose whether
the repository itself should be renamed from `reventless-core` to `reventless` — since `reventless`
is shorter and `reventless-spec` (which lives here) now carries the brand-level `Reventless`
namespace.

## Advantages

- **Shorter, cleaner** — `reventless` is more brandable than `reventless-core` as a repo name.
- **Fits a "hub" framing** — If this repo is the canonical home of the framework, `reventless`
  signals that more naturally than `reventless-core`.

## Consequences & Risks

### 1. Breaks the UI repo's file reference path (concrete blocker)

The UI repo references `rescript-moment` via a file path:
```
"file:../../../reventless-core/rescript/rescript-moment"
```
Renaming would require updating the UI repo's `package.json` and `package-lock.json`, and every
developer would need to re-clone or rename their local checkout.

### 2. Breaks `reventless-core` / `reventless-ui` symmetry

`reventless-core` ↔ `reventless-ui` is a clean, immediately-readable pair. `reventless` ↔
`reventless-ui` is asymmetric and implies `reventless` is the "parent" of `reventless-ui`, which
isn't accurate — they are peers.

### 3. Name mismatch between repo and main package

After the package rename, the primary implementation package in this repo is
`@reventlessdev/reventless-core`. A repo named `reventless` containing a package named
`reventless-core` is dissonant and invites the question: *where is `@reventlessdev/reventless`?*

### 4. The `Reventless` namespace belongs to `reventless-spec`, not the repo

The strongest argument for `reventless` as a repo name would be "the spec carries the Reventless
namespace, and the spec is the public API surface." But this repo contains 16 packages — the name
should reflect the collection, not one package's namespace.

### 5. GitHub URL churn

CI configs, documentation links, and local clone paths all change. Low effort individually but
cumulative noise.

## Decision

**Keep `reventless-core`.**

The `reventless-core` / `reventless-ui` pair is clean, accurate, and symmetric. The main practical
benefit of renaming (shorter name) is outweighed by the file-reference path breakage in the UI repo
and the loss of the pairing that makes the two-repo structure immediately understandable.

## Future Reconsideration

This decision would be worth revisiting if a `@reventlessdev/reventless` meta-package (a façade
re-exporting both spec and core under one import) were ever hosted in this repo. In that scenario,
renaming the repo to `reventless` would align the repo name, the package name, and the `Reventless`
namespace in a coherent way. Until that package exists, there is no compelling reason to rename.
