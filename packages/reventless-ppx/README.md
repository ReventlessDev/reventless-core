[![npm](https://img.shields.io/npm/v/@reventlessdev/reventless-ppx.svg?label=npm)](https://www.npmjs.com/package/@reventlessdev/reventless-ppx)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Docs](https://img.shields.io/badge/docs-reventless.dev-blue)](https://docs.reventless.dev)

# @reventlessdev/reventless-ppx

> ⚠️ **Alpha.** APIs and on-disk formats can change without notice between releases.
> Pin exact versions and expect breaking changes.

The **ReScript PPX** for [Reventless](https://docs.reventless.dev) — a spec-driven,
event-sourced CQRS framework written in [ReScript](https://rescript-lang.org). It
is a compile-time preprocessor (native OCaml binary) that eliminates boilerplate
from Reventless application code by deriving framework metadata and wiring
directly from your component definitions.

## What it provides

A single PPX binary, invoked by the ReScript compiler, that runs a set of
transforms over component source — among them: display-name and reference
inference, DCB tag and read-consistency inference, GWT test inference,
authorization injection, allowed-states annotations, and module-URL derivation.

The package ships as a thin launcher that resolves a **prebuilt per-platform
binary** installed as an optional dependency
(`@reventlessdev/reventless-ppx-<platform>`), published for **macOS arm64** and
**Linux x64** — so it installs automatically with no authentication. On platforms
with no prebuilt binary (e.g. macOS x64, Linux arm64, Windows via WSL2), it is
built from source with the OCaml toolchain (`opam` + `dune`).

## Where it fits

This is build tooling shared across the framework and its example apps, not a
runtime library. It is referenced from a package's `rescript.json` `ppx-flags`
and runs only at compile time.

## Install

```bash
pnpm add -D @reventlessdev/reventless-ppx
```

Register it in `rescript.json`:

```json
{
  "ppx-flags": ["@reventlessdev/reventless-ppx/bin"]
}
```

The matching platform binary is pulled in automatically via optional
dependencies. On an unsupported platform, build from source (requires the OCaml
toolchain):

```bash
cd src && opam exec -- dune build
```

## Links

- 📚 Documentation — [docs.reventless.dev](https://docs.reventless.dev)
- 📦 Repository — [ReventlessDev/reventless-core](https://github.com/ReventlessDev/reventless-core)
- 📋 [Changelog](./CHANGELOG.md)

## License

[Apache-2.0](https://opensource.org/licenses/Apache-2.0)
