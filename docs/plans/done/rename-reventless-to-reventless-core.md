# Plan: Rename `@reventlessdev/reventless` → `@reventlessdev/reventless-core`

## Motivation

The package `@reventlessdev/reventless` (at `reventless/reventless/`) has an ambiguous name — it looks like it represents the entire framework rather than just its core layer. The repository is already named `reventless-core`, and every sibling package has a descriptive suffix (`reventless-spec`, `reventless-aws`, `reventless-in-memory`). Renaming makes the package consistent with the rest of the ecosystem.

---

## Advantages

1. **Clarity of role** — `reventless-core` immediately signals "foundation layer", not "the whole thing".
2. **Naming consistency** — aligns with `reventless-spec`, `reventless-aws`, `reventless-in-memory`.
3. **Repo / package alignment** — the mono-repo is already `reventless-core`; the main package should match.
4. **Reserves `@reventlessdev/reventless`** — leaves the short name available for a future façade/meta-package that re-exports the full framework.
5. **Low external risk** — packages are private, alpha, on GitHub Package Registry; no wide public adoption to break.

---

## Consequences & Risks

| Area | Impact | Mitigation |
|------|--------|------------|
| **npm package name** | Breaking: consumers must update their dependency name | Coordinated bump; alpha stage limits blast radius |
| **ReScript namespace** (see decision below) | If kept as `"Reventless"`: zero source changes. If changed to `"ReventlessCore"`: ~100+ open/reference sites across 3 packages | Keep namespace as `"Reventless"` (recommended) |
| **Directory rename** | Purely structural; git history preserved via `git mv` | Use `git mv` |
| **Root `rescript.json`** | One line update | Trivial |
| **Direct dependents** (2 packages) | Dependency name in `package.json` + `rescript.json` | Update during the rename step |
| **Documentation** | Any docs/CLAUDE.md referencing the old name | Global search-replace |
| **Changelog / semver** | Treated as a breaking change → major alpha bump | Handled by semantic-release on next release |
| **CI/CD** | None — Lerna auto-discovers packages by directory | No changes needed |

---

## Key Decision: ReScript Namespace

The package's `rescript.json` declares `"namespace": "Reventless"`. This namespace is what dependent ReScript files use to qualify modules, e.g. `Reventless.Component`, `open Reventless`.

For reference, `reventless-spec` currently uses `"namespace": "ReventlessSpec"`.

---

**Option A — Keep namespace `"Reventless"` (recommended for minimal change)**
- Zero source code changes in `reventless-aws`, `reventless-in-memory`, or examples.
- The npm package name changes, but the compiled module namespace stays the same.
- Slight conceptual mismatch (package is "reventless-core" but namespace is "Reventless") — acceptable because short namespaces aid readability.

---

**Option B — Change core namespace to `"ReventlessCore"` only**
- Every `open Reventless`, `Reventless.Foo`, `Reventless.Component` reference must be updated in dependent packages (`reventless-aws`, `reventless-in-memory`, `reventless-interop`, examples).
- `reventless-spec` stays as `"ReventlessSpec"` — no change there.
- Estimated impact: 150–200 sites across dependent packages.
- Clean alignment between package name and namespace, but high churn for an alpha package.

---

**Option C — Swap both namespaces: core gets `"ReventlessCore"`, spec gets `"Reventless"`**

This option combines the core package rename with a coordinated namespace swap between the two foundational packages:

| Package | Before | After |
|---------|--------|-------|
| `reventless` (→ `reventless-core`) | namespace `"Reventless"` | namespace `"ReventlessCore"` |
| `reventless-spec` | namespace `"ReventlessSpec"` | namespace `"Reventless"` |

**Advantages:**

1. **Semantic correctness** — `Reventless.Aggregate`, `Reventless.ReadModel`, etc. are *type and interface definitions*, which is exactly what a developer writes when building a plugin. The spec is the language of the framework; it deserves the short, brand-level namespace. The core implementation package is infrastructure — `ReventlessCore` reflects that.

2. **Ergonomics for the common case** — Application code opens the spec constantly (`open Reventless`, `module Spec: Reventless.Aggregate.Spec`). Replacing `open ReventlessSpec` with `open Reventless` removes a redundant suffix everywhere business logic is written.

3. **Consistent with broader ecosystem convention** — In many ecosystems the "root" namespace belongs to the public contract layer (types, interfaces), not the implementation. E.g., `React.FC` is a type, not a runtime builder.

4. **Future-proofs a meta-package** — A future `@reventlessdev/reventless` façade could re-export both spec and core under one import, with `Reventless.*` as the unified public surface.

5. **Clean break at the right moment** — The codebase is in alpha; this is the least costly time to do a sweeping rename. After the first stable release, this becomes much harder to justify.

**Consequences & Risks:**

1. **Largest change surface** — requires touching every file that uses either `ReventlessSpec.*` or `Reventless.*`. Estimated scope:
   - `ReventlessSpec.*` → `Reventless.*`: ~716 occurrences across 195 files
   - `Reventless.*` → `ReventlessCore.*` in dependent packages (`reventless-aws`, `reventless-in-memory`, `reventless-interop`, examples): comparable scale, ~150–200 files
   - Total: approximately **250–300 files** touched, **800–1000 reference sites**

2. **Risk of naming collision inside `reventless-core` itself** — the core package's own source files currently use `ReventlessSpec.Foo` to refer to the spec. After the rename those become `Reventless.Foo`. The core package also declares its own modules with the same names (e.g., `Aggregate`, `Component`). The namespace prefix distinguishes them. This must be verified carefully — the core's own source files do not self-prefix so there is no circular issue, but it must be confirmed that no internal ambiguity arises.

3. **Two interleaved renames** — doing both namespace changes atomically in one PR increases merge complexity. One mistake in the search-replace (e.g., partial replacement of `ReventlessSpec` in a file that also uses `Reventless`) corrupts the build. Scripted replacement (sed/grep pipeline) and per-package incremental build checks are essential.

4. **Compiled output filenames change** — ReScript namespaces are embedded in the `.res.mjs` compiled filenames (e.g., `ReventlessSpec__Aggregate.res.mjs` → `Reventless__Aggregate.res.mjs`). Any code that references compiled paths directly (rare) would break. CI re-runs full build, so no stale artefact risk in a clean environment.

5. **Increased review burden** — a 300-file PR is harder to review. Recommend splitting: first land the package-and-directory rename (Option A), then follow up with the namespace swap as a dedicated mechanical PR.

**Recommendation for Option C:** Implement it in two sequential PRs:
- PR 1: Package rename only (same as Option A).
- PR 2: Namespace swap (`"ReventlessSpec"` → `"Reventless"`, `"Reventless"` → `"ReventlessCore"`), with a scripted sed replacement and per-package build verification at each step.

---

**Overall recommendation: Option A first, Option C as follow-up.** Option A is safe to land immediately. Option C's namespace swap is architecturally superior and worth doing while still in alpha, but it should be its own PR with a scripted migration to manage the surface area.

---

## Affected Files

### Package being renamed
| File | Change |
|------|--------|
| `reventless/reventless/package.json` | `"name": "@reventlessdev/reventless-core"` |
| `reventless/reventless/rescript.json` | `"name": "@reventlessdev/reventless-core"` |
| Directory `reventless/reventless/` | `git mv reventless/reventless reventless/reventless-core` |

### Root configuration
| File | Change |
|------|--------|
| `rescript.json` | `"@reventlessdev/reventless"` → `"@reventlessdev/reventless-core"` in `dependencies` |

### Direct dependents
| File | Change |
|------|--------|
| `reventless/reventless-aws/package.json` | dependency name update |
| `reventless/reventless-aws/rescript.json` | dependency name update |
| `reventless/reventless-in-memory/package.json` | dependency name update |
| `reventless/reventless-in-memory/rescript.json` | dependency name update |

### Documentation / references
| File | Change |
|------|--------|
| `CLAUDE.md` | Package name references |
| `README.md` (root and package-level) | Package name references |
| `packages/doc/docs/**` | Any `@reventlessdev/reventless` import examples |
| `docs/plans/` (this repo) | Historical — no changes needed |

### No changes needed
- All `.res` / `.res.mjs` source files (namespace stays `"Reventless"`)
- `.github/workflows/` (CI/CD auto-discovers packages)
- `lerna.json` (workspace glob patterns unchanged)
- Root `package.json` workspaces (workspace glob `"reventless/*"` still matches)

---

## Step-by-Step Implementation

### Step 1 — Rename the directory
```bash
git mv reventless/reventless reventless/reventless-core
```

### Step 2 — Update the package files
In `reventless/reventless-core/package.json`:
```json
"name": "@reventlessdev/reventless-core"
```

In `reventless/reventless-core/rescript.json`:
```json
"name": "@reventlessdev/reventless-core"
```

### Step 3 — Update root rescript.json and package.json
Replace `"@reventlessdev/reventless"` → `"@reventlessdev/reventless-core"` in `dependencies`.

⚠️ **Name collision gotcha**: The root `rescript.json` (and root `package.json`) was originally named `"@reventlessdev/reventless-core"` — the same as the repo itself. After renaming the sub-package to the same name, ReScript sees the root and the sub-package as the same package and skips building the sub-package, causing "module Reventless not found" errors in dependents. Fix: rename BOTH root files to `"reventless-monorepo"` (a private, never-published identity).

In root `package.json`:
```json
"name": "reventless-monorepo"
```
In root `rescript.json`:
```json
"name": "reventless-monorepo"
```

### Step 4 — Update direct dependents
In `reventless/reventless-aws/package.json` and `rescript.json`:
- `"@reventlessdev/reventless": "^3.x"` → `"@reventlessdev/reventless-core": "^3.x"`

In `reventless/reventless-in-memory/package.json` and `rescript.json`:
- `"@reventlessdev/reventless": "*"` → `"@reventlessdev/reventless-core": "*"`

### Step 5 — Reinstall dependencies
```bash
npm install
```
This regenerates `package-lock.json` with the new package name.

### Step 6 — Verify build & tests
```bash
npm run build
npm run test
```

### Step 7 — Update documentation
Global search-replace `@reventlessdev/reventless` → `@reventlessdev/reventless-core` across:
- `CLAUDE.md`
- `README.md` files
- `packages/doc/docs/`

### Step 8 — Commit
```
feat(reventless-core)!: rename package from @reventlessdev/reventless to @reventlessdev/reventless-core

BREAKING CHANGE: package renamed for consistency with sibling packages and repository name.
ReScript namespace "Reventless" is unchanged — no source code updates required.
```

---

## What Does NOT Need to Change

- The ReScript **namespace** `"Reventless"` — all `.res` source files continue to compile as-is.
- **CI/CD workflows** — Lerna and npm workspaces discover packages via directory glob.
- **Versioning** — the package version continues from where it left off; semantic-release handles the major bump.
- **Examples** — they depend on `reventless-in-memory` transitively; no direct dep on the core package.

---

## Status

### PR 1 — Package rename (Option A) ✅ COMPLETE

- [x] Step 1 — Rename directory (`git mv`)
- [x] Step 2 — Update package files
- [x] Step 3 — Update root `rescript.json` and `package.json` (including name collision fix)
- [x] Step 4 — Update direct dependents (`reventless-aws`, `reventless-in-memory`)
- [x] Step 5 — `npm install`
- [x] Step 6 — Build + test verification (556 modules compiled, 48 tests pass)
- [x] Step 7 — Documentation check (no stale references found)
- [x] Step 8 — Committed: `feat(reventless-core)!: rename package from @reventlessdev/reventless to @reventlessdev/reventless-core`

### PR 2 — Namespace swap (Option C) ✅ COMPLETE

Committed `0fcf24e3` on branch `alpha`: `feat(reventless-spec)!: swap namespaces — spec→Reventless, core→ReventlessCore`

**568 files changed**, 3164 insertions, 3164 deletions.

#### Actual scope (vs estimate)

| Change | Estimated | Actual |
|--------|-----------|--------|
| `ReventlessSpec.` → `Reventless.` | ~716 occurrences / 195 files | ~732 occurrences / 209 files (src only; excl. `.history/`, `lib/`) |
| `Reventless.` → `ReventlessCore.` | ~150–200 files (aws+in-memory) | ~333 files (aws + in-memory) |
| Total files | 250–300 | 568 (includes `.res.mjs` compiled outputs) |

#### Implementation technique: three-step placeholder

To avoid the `Reventless`/`ReventlessSpec` prefix collision (a naive `s/Reventless/ReventlessCore/g` would corrupt `ReventlessSpec` → `ReventlessCoreSpec`):

```bash
# Step 1 — placeholder (all .res/.resi files, monorepo-wide)
find . \( -path ./node_modules -prune -o -path ./.history -prune -o -path ./lib -prune \) \
  -o -name "*.res" -print -o -name "*.resi" -print | ... | xargs sed -i '' 's/ReventlessSpec/__RS__/g'

# Step 2 — core rename (aws + in-memory only)
find reventless/reventless-aws reventless/reventless-in-memory -name "*.res" -o -name "*.resi" | \
  xargs sed -i '' 's/Reventless/ReventlessCore/g'

# Step 3 — restore (all .res/.resi files, monorepo-wide)
find . ... | xargs sed -i '' 's/__RS__/Reventless/g'
```

#### Deviation from plan: additional files requiring step 2

The plan specified step 2 only for `reventless-aws` and `reventless-in-memory`. Two additional file groups also had original `Reventless.X` self-references (referencing `reventless-core`'s own namespace) that were NOT spec references:

1. **`reventless/reventless-core/test-helper/`** (5 files) — used `Reventless.Behavior.T`, `Reventless.Message.errorHandler`, `Reventless.Message.context`, `Reventless.Message.InvalidEvent`, `Reventless.QueryDb`, `Reventless.Projection.Mapping`
2. **`reventless/reventless-core/tests/`** (12 files) — similar self-references in test helpers
3. **`reventless/reventless-core/src/`** (6 files) — `CommandTopic_Adapter.res`, `CommandTopic_Helpers.res`, `EventLog_Operations.res`, `EventMapper_Callback.res`, `CommandPublisher.res`, `FTPHandler.res`

**Fix applied**: for each affected file, fetched original from `git show HEAD:<file>`, applied all three steps to the original content, and wrote back. This correctly distinguished spec references from core self-references.

#### Why the plan's verification check 3 shows 11 (not 0)

Check 3: `grep -r "ReventlessCore" reventless/reventless-core/src --include="*.res"` → expected 0.

After applying the full three steps to the 6 core src files, `Reventless.X` self-references (original core namespace) correctly became `ReventlessCore.X`. This is valid — ReScript allows using the fully-qualified namespace even within the same package, and `CommandTopic_Helpers.res` even has a comment explaining the intent:
```
// Re-export from spec so ReventlessCore.CommandTopic.topicItem === Reventless.CommandTopic.topicItem
```
The build succeeds (556 modules compiled), so these 11 occurrences are correct behaviour, not errors.

#### rescript.json changes

| File | Before | After |
|------|--------|-------|
| `reventless/reventless-spec/rescript.json` | `"namespace": "ReventlessSpec"` | `"namespace": "Reventless"` |
| `reventless/reventless-core/rescript.json` | `"namespace": "Reventless"` | `"namespace": "ReventlessCore"` |

#### Final verification

- `grep -r "ReventlessSpec" reventless/ --include="*.res" | grep -v "/lib/"` → **0 results** ✓
- Build: **556 modules compiled** ✓
- Tests: **48/48 passed** ✓
