# Keep prebuilt binaries out of the repository

Scope: stop committing native build artifacts to git — primarily the per-platform
`reventless-ppx` binaries (`ppx-*.exe`) — to end history bloat, and define where
they live instead so CI and developers fetch only the binary they need, built
**once per version** rather than rebuilt on every framework build.

Status: **linux-x64 cutover COMPLETE (2026-05-27); macOS deferred.** Thin main +
per-platform `@reventlessdev/reventless-ppx-linux-x64@1.0.0-alpha.26` published
to the registry, committed `ppx-linux.exe` removed from the tree, repo-wide
`*.exe` gitignore added, vestigial `install.cjs` + `bin.cmd` dropped. Bookworm
+ workspace-consumer verification on Linux confirms the registry serves the
binary; the launcher resolves it via `optionalDependencies`. The macOS matrix
entries in `publish-ppx.yml` remain commented out — `darwin-arm64` / `darwin-x64`
are deferred until the GitHub-side "disruptive" workflow flag clears and macOS
CI cost is acceptable. `ppx-osx-x64.exe` therefore stays tracked as the macOS
local-fallback (gitignore patterns don't affect already-tracked files); once
macOS targets publish, that binary gets removed and the cutover finishes.

**Earlier sub-milestones (already landed before 2026-05-27):** the launcher /
per-platform scaffolds / publish workflow rewrite / lerna exclusion of
`reventless-ppx` / GitHub Packages overage unblock / redundant per-package
lockfile cleanup. Renaming `build-ppx.yml` → `publish-ppx.yml` (2026-05-26)
bypassed a GitHub-side flag that returned HTTP 500 on dispatch.

**Regression caught by Step 5 verification (2026-05-27):** the first published
`reventless-ppx-linux-x64@1.0.0-alpha.24` binary was built on `ubuntu-latest`
(Ubuntu 24.04, glibc 2.39) and floored consumers at GLIBC 2.38, excluding
Debian Bookworm, Ubuntu 22.04, Amazon Linux 2/2023, etc. Fixed by pinning the
matrix to `ubuntu-22.04` (glibc 2.35) and republishing as `alpha.26`. Lesson
codified in the workflow file's matrix comment — future readers should not
revert to `ubuntu-latest` without a deliberate portability re-assessment.

## Incident — alpha.22 (2026-05-25)

Thinning the main `files` list **before** the per-platform packages existed, while
`reventless-ppx` was still in the lerna release scope, caused the normal release
to publish `@reventlessdev/reventless-ppx@1.0.0-alpha.22` with **no binary and no
`optionalDependencies`** (the dedicated `build-ppx.yml` only triggers on `src/**`,
which didn't change, so no per-platform package was published). Core itself was
unaffected (examples use `workspace:*`), but registry consumers resolving the new
version broke.

Compounding fact learned: **GitHub Packages does not honor manual `dist-tag`
moves** — `npm dist-tag add … latest` reports success but `latest` stays on the
most-recently-published version. So a broken publish can only be superseded by
publishing a newer good version (not by re-tagging), and broken versions are best
removed via the GitHub Packages UI/API.

**Resolution:** reverted `files` to fat → the next lerna release publishes a
working fat `alpha.23` (binaries bundled), which becomes `latest`. The
per-platform cutover is deferred until the ordering below is in place.

**Rule:** do **not** thin `files` (or add `optionalDependencies`) until
`reventless-ppx` is first removed from the lerna release — otherwise the thinning
rides the normal release train and ships binary-less.

## Progress

**Landed — linux-x64 cutover complete:**
- **Step 0 (lerna exclusion, earlier).** `--ignore-changes reventless-ppx` in
  the `lerna version` calls (release.yml); pattern matches by package name even
  though the glob is loose — verified empirically by post-pivot lerna releases.
- **Launcher** (`packages/reventless-ppx/bin`): pure-shell resolver — finds
  `@reventlessdev/reventless-ppx-<platform>/ppx.exe` (sibling + nested
  `node_modules`, covering npm-flat / pnpm-store / pnpm-workspace layouts), else
  falls back to a local built binary. Validated on Intel Mac (committed
  `ppx-osx-x64.exe` fallback) and Debian Bookworm (registry-served binary).
- **Per-platform publish scaffolds**: `packages/reventless-ppx/npm/{linux-x64,
  darwin-arm64,darwin-x64}/package.json` with `os`/`cpu`. Not pnpm workspace
  members (`packages/*` is single-level).
- **`publish-ppx.yml`** (renamed from `build-ppx.yml`): per-OS matrix → publish
  per-platform + main. Binary `git commit-back` removed. Triggers only on
  `packages/reventless-ppx/src/**` (+ dispatch). **`ubuntu-22.04` pin** on the
  linux-x64 row (glibc 2.35) — see Status header for the regression that forced
  this.
- **Step 1, 1a/2, 3, 4** (publish pipeline): per-platform
  `reventless-ppx-linux-x64@1.0.0-alpha.26` and thin main
  `reventless-ppx@1.0.0-alpha.27` (lerna-bumped from `alpha.26` published by
  `publish-ppx.yml`) live on the registry. Lockfile updated to match.
- **Step 5** (verify installable): scratch `npm i @reventlessdev/reventless-ppx@latest`
  on Bookworm pulls thin main + linux-x64@alpha.26 via `optionalDependencies`,
  the launcher exec's the registry binary, and the binary prints its own help.
  Linux consumer-style install (`npm i hybrid-platform-in-memory@latest +
  reventless-ppx@latest`) on Bookworm passes the same way; no committed `.exe`
  exists in the tarball.
- **Step 6** (delete committed Linux binary): `packages/reventless-ppx/ppx-linux.exe`
  removed; `packages/reventless-ppx/.gitignore` added for `*.exe`. `ppx-osx-x64.exe`
  stays tracked — it is still the macOS local fallback (gitignore patterns do
  not affect already-tracked files).
- **Step 7** (repo-wide gitignore policy): root `.gitignore` now ignores `*.exe`
  and `**/reventless-layer*.zip`. The `rescript-node-zlib` test fixture `.gz` is
  intentionally unaffected.
- **Step 8 (independent cleanup, earlier):** removed the 15 redundant per-package
  `package-lock.json`; gitignored `package-lock.json`.
- **Vestigial `install.cjs` + `bin.cmd` dropped.** Both only acted on a
  `ppx-windows.exe` that is no longer built, shipped, or referenced. Windows
  consumers go via WSL2 → linux-x64, which uses the shell `bin` launcher.

**Deferred — macOS re-enablement (Cutover runbook continues):**
- Un-comment `darwin-arm64` / `darwin-x64` rows in `publish-ppx.yml`.
- Bump per-platform + main, add darwin entries to main's `optionalDependencies`.
- After they publish and verify, `git rm packages/reventless-ppx/ppx-osx-x64.exe`.
- Gate: GitHub-side "disruptive" workflow flag clears and macOS CI cost is
  acceptable.

**Out of scope:** git history rewrite to purge already-committed binaries (Step 9).

## Cutover runbook

Steps 0–7 below are now **done** for `linux-x64`. The runbook remains as the
template for the macOS re-enablement: re-execute steps 1–7 with the macOS
matrix rows un-commented and `optionalDependencies` extended.

0. ✅ **Lerna exclusion.** `--ignore-changes reventless-ppx` in `lerna version`
   calls in `release.yml`. Note: the glob is loose but lerna treats it as a
   package-name filter — empirically confirmed by post-pivot releases where
   reventless-ppx only republishes when its own files change (and only the thin
   main, never per-platform).
1. ✅ **Publish per-platform packages first.** `reventless-ppx-linux-x64@1.0.0-alpha.24`
   published 2026-05-26; superseded by `@1.0.0-alpha.26` (glibc-portable) on
   2026-05-27.
1a. ✅ **Thin main + add `optionalDependencies`.** Thinned in commit
    `9704bc76a` (2026-05-26); lockstep alpha.26 bump in `291fa9f6c` (2026-05-27)
    after pinning the matrix to ubuntu-22.04.
2. ✅ **`optionalDependencies` on main.** Currently only `-linux-x64@alpha.26`;
   macOS entries pending matrix re-enablement.
3. ✅ **GitHub Packages headroom.** Resolved 2026-05-25 by setting the org
   Packages spending limit.
4. ✅ **Thin main published.** `reventless-ppx@1.0.0-alpha.27` (lerna-bumped
   from alpha.26) is `latest` in the registry.
5. ✅ **Verify installable.** Bookworm (glibc 2.36) and Ubuntu 24.04 both pull
   `-linux-x64@alpha.26` via `optionalDependencies`; launcher exec's the
   registry binary. Alpine fails (musl) — expected, out of scope. (The in-repo
   `pnpm install + examples build with .exe moved aside` check is covered by
   the Linux consumer-style install, which already excludes any committed
   `.exe` because the published tarball contains no binary.)
6. ✅ **Committed Linux binary removed.** `packages/reventless-ppx/ppx-linux.exe`
   git-rm'd; `packages/reventless-ppx/.gitignore` adds `*.exe`. `ppx-osx-x64.exe`
   stays tracked until macOS targets publish.
7. ✅ **Repo-wide `.gitignore` policy.** Root `.gitignore` adds `*.exe` and
   `**/reventless-layer*.zip`. Test fixture
   `rescript/rescript-node-zlib/src/example/test.txt.gz` intentionally
   unaffected (no `.zip`/`.gz` glob at the root level).
8. **(Separate / out of scope)** history rewrite to purge the already-committed
   binaries.

### macOS re-enablement (pending)

When the GitHub-side "disruptive" workflow flag is lifted and macOS CI cost is
acceptable:

1. Un-comment the `macos-14` (darwin-arm64) and `macos-13` (darwin-x64) rows in
   `publish-ppx.yml`'s matrix.
2. Bump `packages/reventless-ppx/npm/{darwin-arm64,darwin-x64}/package.json` to
   the next target version.
3. Bump `packages/reventless-ppx/package.json` to the same version and extend
   `optionalDependencies`:
   ```json
   "optionalDependencies": {
     "@reventlessdev/reventless-ppx-linux-x64":    "1.0.0-alpha.NN",
     "@reventlessdev/reventless-ppx-darwin-arm64": "1.0.0-alpha.NN",
     "@reventlessdev/reventless-ppx-darwin-x64":   "1.0.0-alpha.NN"
   }
   ```
4. Refresh `pnpm-lock.yaml`, commit, push.
5. `workflow_dispatch publish-ppx.yml` with `publish=true`.
6. Verify on macOS arm64 + Intel Mac (or a `macos-13`/`macos-14` runner).
7. `git rm packages/reventless-ppx/ppx-osx-x64.exe`.

## Problem

The ReScript PPX is a native OCaml binary compiled per platform. Today every
platform binary is **committed to git** *and* bundled into the npm package:

- `packages/reventless-ppx/ppx-linux.exe`, `ppx-osx-x64.exe` are tracked in HEAD
  (the `files` list also names `ppx-windows.exe`, `ppx-linux-arm.exe`,
  `ppx-osx.exe`).
- Each is ~25 MB. Every PPX version bump commits fresh binaries per platform.

This is the dominant source of repo bloat: `.git` is **437 MB**, of which
`ppx-linux.exe` accounts for ~740 MB across 31 historical versions and
`ppx-osx-x64.exe` ~523 MB across 33 (poorly-compressible binaries that delta
badly and dominate the pack). The now-disabled `build-ppx.yml` encodes the cause
— a per-OS matrix that ended in `git add packages/reventless-ppx/ppx-osx.exe` →
`git commit -m "chore(ppx): update prebuilt binaries [skip ci]"` → `git push`
(see the commented block, lines ~159-164).

They are committed because: (a) the npm package needs them present at pack time;
(b) workspace consumers (the `examples/**`) need the binary to run `rescript
build`; (c) building requires the opam/dune OCaml toolchain that not every dev or
CI runner has. The cost of solving (a)-(c) by committing is the bloat.

## Current mechanism

- **Source:** `packages/reventless-ppx/src/**` (dune project; `dune build` via
  `opam`, scripts `build:ppx` / `clean:ppx`).
- **Distribution:** all platform binaries listed in `files` of
  `@reventlessdev/reventless-ppx`; a `bin` shell script dispatches to the right
  one via `uname`; `install.cjs` (postinstall) only renames the Windows binary.
  Published to GitHub Packages. This is the **fat-package model** — one tarball
  ships ~5 binaries (~125 MB); every install pulls all platforms even though one
  is used.
- **Consumption:** `examples/**/rescript.json` reference `@reventlessdev/reventless-ppx`
  in `ppx-flags`, resolved through the workspace symlink.

## Principles

1. Git stores PPX **source only** — never the compiled `.exe`.
2. Each platform binary is built **once per PPX version**, not per framework build.
3. Consumers fetch **only their platform's** binary, from a versioned store.
4. Local PPX development builds **only the local platform**.

## Where the binaries should live (the storage question)

| Store | Role | Notes |
|---|---|---|
| **npm registry** (GitHub Packages now; npm when public) | **Primary** | Versioned, immutable, cached by the pnpm/npm store. CI's "Linux PPX" = install `@reventlessdev/reventless-ppx[-linux-x64]@<version>`; reused from cache across builds, **never recompiled**. |
| **GitHub Release assets** (raw per-platform `.exe`) | Optional secondary | For Docker images, non-npm consumers, debugging. `install.cjs` could fall back to downloading from here. |
| **git** | **Never** | The whole point of this plan. |

**Answer to "where do CI binaries live / why not rebuilt every build":** in the
**published package on the registry**, pinned to a version. The expensive opam
build runs only in the dedicated PPX-build workflow when the PPX *source* changes;
every other CI job and every developer consumes the cached published binary.

## Options — distribution model

| # | Approach | How | Trade-off |
|---|---|---|---|
| **B** | **Per-platform `optionalDependencies` packages** *(recommended — the esbuild/swc/biome model)* | Split into a thin main `@reventlessdev/reventless-ppx` (launcher + `optionalDependencies`) and **CI-published** per-platform packages — `-linux-x64`, `-darwin-arm64`, `-darwin-x64` (+ `-linux-arm64` if needed) — each carrying one binary with `os`/`cpu` fields. npm/pnpm installs **only the matching** package. (`darwin-x64` is a **sunsetting** CI target — see Platform matrix; a local build remains as the fallback.) | "Only what's needed locally" is enforced by `os`/`cpu`; Linux CI pulls ~25 MB, not ~125 MB. Industry standard, clean git, cached store. Cost: CI publishes N small packages; launcher resolves the installed one. |
| **A** | **Stop committing, keep fat package** | Gitignore the `.exe`; CI builds the matrix and publishes the existing fat package per version; a workspace bootstrap fetches the local platform binary for builds. | Smallest change; keeps `bin`-dispatch + `install.cjs`. Still ships all platforms per install (~125 MB); bootstrap is slightly awkward. |
| **C** | **Thin package + postinstall download** | Single package; `install.cjs` downloads the right binary from a GitHub Release on postinstall, with checksum + cache. | One package; but postinstall network download is fragile (firewalls, offline/CI installs, checksum upkeep) and the ecosystem has moved away from it. Keep only as the Option-B fallback path. |

## Build-once mechanics (not rebuilt on every build)

- **Dedicated PPX-build workflow.** Re-enable `build-ppx.yml`'s per-OS matrix;
  trigger it **only** on changes to `packages/reventless-ppx/src/**` (or a PPX
  version tag) — **not** on every framework build. **Remove** the
  `git add/commit/push` of binaries (lines ~159-164); replace with **publish**
  (per-platform packages, Option B) + optional **release-asset upload**.
- **Everyone else consumes the published, version-pinned package.** Framework CI
  and devs get the binary from the registry via the pnpm/npm store cache —
  downloaded once per version, never compiled. The framework build never invokes
  opam.
- **Make the PPX-build job itself fast on re-run:** cache the opam switch + dune
  `_build` keyed by a hash of `src/**` + `dune-project` (`dune-cache: true` is
  already set); the existing `Dockerfile` gives a reproducible Linux build.
- Version-pinning the PPX also aligns with the clean-rebuild-after-PPX-bump
  discipline (a bump is a deliberate, visible event).

## Recommendation

**Option B + the dedicated build-once workflow.** Git holds only PPX source and
the JS launcher; each platform binary is published once per version and pulled
on demand, matching the platform, from the registry cache.

### Platform matrix

| Platform | Built where | Published? | Tracked? |
|---|---|---|---|
| `linux-x64` | CI (`ubuntu-latest`) | **Yes** | No |
| `darwin-arm64` (Apple Silicon) | CI (`macos-14`/`15`) | **Yes** | No |
| **`darwin-x64` (Mac Intel)** | CI (`macos-13`) — **sunsetting** | **Yes** | **No (gitignored)** |
| `linux-arm64` | CI — optional, only if ARM-Linux CI exists | If needed | No |
| `win32-x64` | — use WSL2 → `linux-x64` | No | No |

`linux-x64` + `darwin-arm64` + `darwin-x64` are the standard published trio for a
native-binary npm package (esbuild/swc/biome all ship `darwin-x64`), so an OSS
contributor on **any** of those — including an Intel Mac — gets a zero-friction
`pnpm install` with no OCaml/opam toolchain. The build-once model means each runs
only on PPX version bumps, so the CI cost is a few runs a year.

**`darwin-x64` is a sunsetting target.** GitHub is retiring Intel macOS runners
(`macos-13` is the last Intel image; `macos-14`/`15` are arm64), and Intel Macs are
declining. Add it **now** via `macos-13` (the easy native path, while the window is
open). **Review trigger: when `macos-13` is retired** — decide then between
migrating to a **Rosetta `arch -x86_64`** job on an arm64 runner vs. **dropping**
`darwin-x64`, based on actual Intel-Mac contributor data at that point. Do **not**
pre-build the Rosetta path now. The locally-built `darwin-x64` (below) remains a
fallback regardless of the CI target's fate.

A `darwin-x64` build runs on **any Intel Mac, any macOS version** (macOS is
backward-compatible). Apple Silicon Macs use the native `darwin-arm64` package, not
this one — the `bin` dispatch selects by `uname -m`, so Rosetta never enters normal
operation (and Apple is winding Rosetta 2 down anyway). Windows is served via WSL2
(which uses `linux-x64`), not a native build.

### Bootstrap resolution (how the repo builds with no committed binary)

- **Framework devs / CI** depend on the **published, pinned** PPX version;
  `pnpm install` fetches the matching platform package (cached). They never build
  the PPX. The per-platform binary packages are **published artifacts, not
  workspace source**, which avoids the "binary missing from a fresh checkout"
  problem.
- **PPX developers** (rare) run `pnpm build:ppx` (opam) to build **only their
  platform**, test, then bump the version → CI builds + publishes the CI targets.
- **Local-build fallback (any platform, incl. Intel Mac).** The launcher resolves
  the published platform package first, then **falls back to a locally-built binary
  in the package directory** (e.g. `ppx-osx-x64.exe`) — gitignored, never
  committed. This covers PPX hackers who just rebuilt, and the case where a
  published platform package is absent. For Mac Intel specifically: `darwin-x64` is
  CI-published (Platform matrix), so `pnpm install` normally suffices; the local
  build is the fallback if/when that CI target is dropped at `macos-13` retirement.

## Implementation sketch

**Order matters: publish first, delete second.** There must never be a window
where the binary is *neither* in git *nor* in the registry — so the committed
binaries stay until the per-platform packages are published and verified
installable. The steps below are in safe cutover order.

1. **Restructure the package** (no deletions yet — nothing breaks). Thin main
   (`optionalDependencies` on the platform packages + a launcher that resolves the
   installed one) and per-platform binary packages with `os`/`cpu` fields for the
   CI targets (`linux-x64`, `darwin-arm64`, `darwin-x64`, …). (`darwin-x64` is
   published via `macos-13` but **sunsetting** — Platform matrix; the local build
   stays as a fallback.) **Keep the currently-committed `.exe` in place for now.**
   (Option A: skip the split; keep the fat package.)
2. **Re-enable `build-ppx.yml`:** per-OS matrix build; **drop** the binary
   git-commit-back; add per-platform `npm publish` + (optional) `gh release upload`;
   trigger on `src/**` change / version tag.
3. **First publish (the pivot).** Bump the PPX version (e.g. `1.0.0-alpha.20` →
   `…21`) and run the workflow **once** (manual dispatch or the version tag). This
   is the **first time** the per-platform packages exist in the registry —
   `@reventlessdev/reventless-ppx@…21` (thin) + `-linux-x64` / `-darwin-arm64` /
   `-darwin-x64` @ the same version. Confirm they are installable.
4. **Update `install.cjs` / the launcher** to locate the platform package's binary
   (Option B), **with a fallback to a locally-built binary in the package dir**
   (`packages/reventless-ppx/ppx-osx-x64.exe`) — the fallback covers PPX hackers
   who just rebuilt, and the case where a platform package is absent (e.g. if the
   sunsetting `darwin-x64` CI target is later dropped). The existing `bin` script
   already dispatches `Darwin-x86_64 → ppx-osx-x64.exe`, so keep that path
   resolving the published package's binary first, then the gitignored local file
   (and replace the bundled-binary `uname` dispatch for the published platforms).
   Make the `build:ppx` output land at that path on Intel Macs.
5. **Point consumers at the published, pinned PPX version**; verify a clean
   `pnpm install` + an `examples/**` `rescript build` resolves the PPX **from the
   registry with no committed binary present** (temporarily move the local `.exe`
   aside to prove it). The registry is now the source of truth.
6. **Only now: remove the committed binaries.** `git rm --cached
   packages/reventless-ppx/*.exe`; add `packages/reventless-ppx/*.exe` and
   `packages/reventless-ppx/bin.exe` to `.gitignore` (keep `bin`, `bin.cmd`,
   `install.cjs`, `src/**`). With the registry serving the binaries, this is a
   no-op for consumers — no gap.
7. Add a general build-artifact `.gitignore` policy (`*.exe`, layer `*.zip`,
   bundles). Document the one intentional exception: the tiny test fixture
   `rescript/rescript-node-zlib/src/example/test.txt.gz` (a test *input*, not a
   build artifact — keep).
8. **Remove the redundant per-package `package-lock.json`** (see below), once
   confirmed unused: `git rm` the 15 files and `.gitignore` `package-lock.json`
   under workspace packages. **Keep the root `pnpm-lock.yaml`.**

After this one-time cutover, subsequent publishes happen **only on PPX version
bumps** (the workflow's `src/**` / version-tag trigger) — never on a normal
framework build.

### Publish prerequisite: GitHub Packages storage

The first-publish pivot (step 3) and every later publish require **headroom under
the org's GitHub Packages storage limit**. Private packages count against the
quota, and the fat package is ~125 MB per version, so a few alpha releases exhaust
it and block `npm publish`.

**Learned (2026-05-25): the block is overage *enforcement*, not instantaneous
usage.** Deleting package versions did **not** lift it; **setting an org budget /
spending limit for Packages did** (resolved 2026-05-25). So:

- **Raise the org spending limit / set a Packages budget** — the reliable unblock
  (overage ≈ $0.25/GB-month → pennies; needs `admin:org`, UI).
- **Pruning old versions is cleanup, not a reliable unblock** — it reduces stored
  bytes and ongoing cost but does not necessarily lift an overage block mid-cycle.
  (We deleted `reventless-ppx` alpha.18/.19 ≈ 250 MB anyway; keep the in-use
  `alpha.20`.)
- **This plan permanently relieves the pressure:** per-platform packages are
  ~25 MB each (only the matching one is downloaded), so the fat 125 MB versions go
  away after the cutover.

Public packages on GitHub Packages are free, so going public would also remove
this limit — but that is a separate release decision, **out of scope here**, and
must not be driven by this storage constraint.

### Related HEAD hygiene: redundant per-package lock files

Distinct from binaries, but the same "stop tracking redundant files" goal. The
workspace is pnpm-managed, so the **root `pnpm-lock.yaml` is the authoritative
lock and must stay tracked** — it pins the whole workspace for reproducible
installs. Alongside it, **15 per-package `package-lock.json`** (under `rescript/*`,
`reventless/*`, `packages/doc`) are **stale npm-era leftovers**: pnpm does not
consume them, and a dependency's lockfile is never honored by consumers anyway
(only the top-level project's lockfile is). Removing them is **zero-impact on
reproducibility** — nothing installs from them; it is purely cruft removal (and
unlike the binaries, lock files are text that delta-compresses, so this is hygiene,
not a bloat fix).

**Verification gate:** before deleting, confirm no workflow or contributor runs a
standalone `npm install` inside those package directories; if any does, convert it
to the pnpm workspace install first.

## Verification

- `git ls-files | grep -E '\.exe$'` → empty.
- Fresh `pnpm install` on Linux pulls **only** the linux binary; on macOS only
  darwin; an `examples/**` `rescript build` succeeds **without** opam present.
- The PPX-build workflow runs **only** on `src/**` changes; a normal framework CI
  run does **not** compile the PPX and shows a store cache hit on the pinned PPX
  version.
- Repo `.git` stops growing on PPX version bumps.

## Out of scope

- **Removing the already-committed binaries from history.** That is a one-time
  history cleanup tracked separately; this plan stops *future* tracking and new
  bloat.
- **Layer ARN / deploy-state files.** See the sibling plan "Move CI deploy state
  out of the repository". Build artifacts such as the Lambda layer `*.zip` follow
  the same policy as here — produced by CI, distributed via the registry / Release
  assets / direct publish, **never committed** (the layer zips are already
  untracked; this plan's `.gitignore` policy keeps them that way).
