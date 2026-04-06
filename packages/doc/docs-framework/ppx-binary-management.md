---
title: PPX Binary Management
sidebar_position: 4
---

# PPX Binary Management

The `@reventlessdev/reventless-ppx` package ships prebuilt native binaries — one per target platform. This document explains the binary format, how installation works, how to build locally, and the current CI situation.

## How It Works

The PPX is an OCaml program compiled by [dune](https://dune.build/). ReScript invokes it at compile time via the `ppx-flags` entry in `rescript.json`:

```json
"ppx-flags": ["@reventlessdev/reventless-ppx/bin", "sury-ppx/bin"]
```

After `npm install`, the `postinstall` script (`install.cjs`) copies the correct platform binary to `packages/reventless-ppx/bin`, which is the path ReScript calls.

## Platform Binaries

| File | Platform |
|------|----------|
| `ppx-linux.exe` | Linux x64 |
| `ppx-linux-arm.exe` | Linux arm64 |
| `ppx-osx.exe` | macOS arm64 (Apple Silicon) |
| `ppx-osx-x64.exe` | macOS x64 (Intel) |
| `ppx-windows.exe` | Windows x64 |

All binaries are committed to the repository and included in the npm package via the `files` field in `package.json`.

## Current CI Situation

| Platform | Built in CI? | Notes |
|----------|-------------|-------|
| Linux x64 | Yes | Built by the PPX test job (`ubuntu-latest`) — binary committed after a successful test run |
| Linux arm64 | No | Must be built locally |
| macOS arm64 | No | Must be built locally — `macos-14` runner was removed to avoid CI failures after GitHub deprecated free `macos-13` (x64) runners |
| macOS x64 | No | `macos-13` runners are no longer available on GitHub Actions |
| Windows | No | Must be built locally |

The CI workflow (`build-ppx.yml`) now only runs PPX tests on Linux. **macOS binaries must be built and committed manually** whenever the PPX source changes.

## Prerequisites for Local Builds

You need [opam](https://opam.ocaml.org/) and OCaml installed:

```bash
# Install opam (macOS)
brew install opam

# Initialize opam (first time only)
opam init

# Create a switch with OCaml 5.2.x
opam switch create 5.2.0
eval $(opam env)
```

Install the OCaml dependencies (run once per machine, or after opam reinstall):

```bash
cd packages/reventless-ppx/src
opam install . --deps-only --yes
```

Dependencies (from `reventless-ppx.opam`):
- `ocaml >= 4.12.1`
- `dune >= 3.19`
- `ppxlib = 0.34.0`
- `yojson >= 2.0.0`

## Building Locally

From the repo root:

```bash
cd packages/reventless-ppx
npm run build:ppx
```

Or directly with dune:

```bash
cd packages/reventless-ppx/src
opam exec -- dune build
```

The compiled binary lands at:

```
packages/reventless-ppx/src/_build/default/bin/bin.exe
```

## Copying the Binary

After building, copy the binary to the correct platform file:

```bash
# macOS arm64 (Apple Silicon)
cp packages/reventless-ppx/src/_build/default/bin/bin.exe \
   packages/reventless-ppx/ppx-osx.exe
chmod +x packages/reventless-ppx/ppx-osx.exe

# macOS x64 (Intel)
cp packages/reventless-ppx/src/_build/default/bin/bin.exe \
   packages/reventless-ppx/ppx-osx-x64.exe
chmod +x packages/reventless-ppx/ppx-osx-x64.exe

# Linux x64
cp packages/reventless-ppx/src/_build/default/bin/bin.exe \
   packages/reventless-ppx/ppx-linux.exe
chmod +x packages/reventless-ppx/ppx-linux.exe

# Linux arm64
cp packages/reventless-ppx/src/_build/default/bin/bin.exe \
   packages/reventless-ppx/ppx-linux-arm.exe
chmod +x packages/reventless-ppx/ppx-linux-arm.exe
```

Then run the tests to verify:

```bash
cd packages/reventless-ppx
npm test
```

Finally, commit the updated binary:

```bash
git add packages/reventless-ppx/ppx-osx.exe   # adjust for your platform
git commit -m "chore(ppx): update prebuilt macOS arm64 binary"
```

## Running PPX Tests

The test suite compiles mini ReScript packages through the PPX and checks the generated JS output:

```bash
cd packages/reventless-ppx
npm test
```

This runs `test/run.sh`, which:
1. Builds the PPX from source (so you get the latest local changes)
2. Creates temporary ReScript packages in `/tmp`
3. Compiles them with `npx rescript build`
4. Asserts expected patterns in the generated `.res.mjs` output

The test suite covers all PPX annotations: `@@reventless.spec`, `@@reventless.behavior`, `@@reventless.dcbTags`, `@reventless.projections`, `@partitionTag`, `@noTag`, `@dcbTag`, and `@compositePartitionTag`.

## Workflow When Changing PPX Source

1. Edit files in `packages/reventless-ppx/src/ppx/`
2. Run `npm test` from `packages/reventless-ppx/` — this rebuilds and tests in one step
3. Copy the binary to the appropriate platform file(s)
4. Commit both the source change and the updated binary

## Future CI Improvements

Restoring CI builds for macOS requires a runner with native arm64 support. Options:

- **`macos-14` or `macos-15`** — GitHub-hosted arm64 runners (free for public repos). Produces `ppx-osx.exe`. Would require re-adding the `build` and `assemble` jobs to `build-ppx.yml`.
- **Self-hosted runner** — A dedicated macOS machine registered as a GitHub Actions runner. More control, no runner availability issues.
- **Cross-compilation** — Build the macOS binary from Linux using a cross-compiler toolchain (complex setup, not currently attempted).

When CI is re-enabled for macOS, the `assemble` job in `build-ppx.yml` handles downloading all platform artifacts and committing them to the repo automatically.
