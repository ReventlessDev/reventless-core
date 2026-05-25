# reventless-ppx per-platform packages

These are **publish templates** for the per-platform binary packages
(`@reventlessdev/reventless-ppx-<platform>`). Each directory holds only a
`package.json` with `os`/`cpu` constraints; the native `ppx.exe` is **built and
injected by CI** (`.github/workflows/build-ppx.yml`) at publish time and is
**never committed to git** (see `.gitignore` here).

The thin main package `@reventlessdev/reventless-ppx` declares these as
`optionalDependencies`, so `npm`/`pnpm` install **only** the one matching the
host's `os`/`cpu`. The main package's `bin` launcher resolves the installed
platform package's binary, falling back to a locally-built binary in the main
package directory (for PPX development).

> These directories are **not** pnpm workspace members (the workspace globs are
> single-level: `packages/*`), so they are not installed locally — they exist
> solely to be packed and published by CI.

## Platform targets

| Directory | Package | Runner |
|---|---|---|
| `linux-x64` | `@reventlessdev/reventless-ppx-linux-x64` | `ubuntu-latest` |
| `darwin-arm64` | `@reventlessdev/reventless-ppx-darwin-arm64` | `macos-14` |
| `darwin-x64` | `@reventlessdev/reventless-ppx-darwin-x64` | `macos-13` (sunsetting) |

Add `linux-arm64` only if an ARM-Linux CI runner becomes available. Windows is
served via WSL2 (which uses `linux-x64`).

## Versioning

All platform packages **and** the main package are versioned in **lockstep** —
bump them together (the deliberate "PPX version bump" event) before publishing.
