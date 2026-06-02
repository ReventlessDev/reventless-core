# Reventless Core

**Reventless** is a modern holistic approach for the development of event-based business applications, consisting of:

- A *Methodology* which covers the full delivery cycle
- A *Programming Model* which focuses on business value
- A *Domain Independent* reusable *Framework* to optimize operational costs

It enables developers to focus on business value and ship fast by providing a hierarchical component model that guides towards best-practice architectural patterns, with everything evolving around commands & events that are part of a ubiquitous language shared across all stakeholders.

## Core Technologies & Patterns

Reventless leverages modern architectural patterns and technologies:

- **Domain-Driven Design (DDD)** - Aligns software design with business domains and ubiquitous language
- **Event-Driven Architecture** - Asynchronous message-based communication between components
- **Event Sourcing** - Stores application state as a sequence of events (source of truth)
- **CQRS** - Separates read and write operations for optimized performance and scalability
- **ReScript** - Type-safe functional programming language compiling to JavaScript, see [here](https://rescript-lang.org)
- **AWS Serverless** - Cloud-native deployment using Lambda, DynamoDB, SQS, SNS, and more
- **Infrastructure as Code (IaC)** - Automated infrastructure provisioning and management using [Pulumi](https://pulumi.com)
- **Hierarchical Component Model** - Modular, reusable architectural components with built-in infrastructure definitions (via Pulumi)

## 📦 Packages

This is a [pnpm](https://pnpm.io) + [Lerna](https://lerna.js.org) monorepo. Packages are grouped by type into four workspace folders:

| Folder | Purpose |
|--------|---------|
| [`reventless/`](reventless/) | Reventless framework + extension packages |
| [`rescript/`](rescript/) | ReScript bindings for JS/npm libraries |
| [`examples/`](examples/) | Example applications |
| [`packages/`](packages/) | Build tooling and documentation only |

### Framework (`reventless/`)

- [reventless-spec](reventless/reventless-spec/) — type specifications and interfaces
- [reventless-core](reventless/reventless-core/) — core framework (provider-agnostic)
- [reventless-aws](reventless/reventless-aws/) — AWS adapters (DynamoDB, Lambda, SQS, SNS, S3)
- [reventless-in-memory](reventless/reventless-in-memory/) — in-memory platform for local dev and testing
- [reventless-infra](reventless/reventless-infra/), [reventless-interop](reventless/reventless-interop/), [reventless-gwt](reventless/reventless-gwt/), [reventless-codegen](reventless/reventless-codegen/)

### ReScript bindings (`rescript/`)

`rescript-aws-sdk`, `rescript-pulumi-aws`, `rescript-pulumi-pulumi`, `rescript-uuid`, `rescript-fast-csv`, `rescript-hash-object`, `rescript-node-streams`, `rescript-node-zlib`, `rescript-ssh2`, `rescript-graphql-yoga`, `rescript-moment` (shared with the UI repo).

### Examples (`examples/`)

- [online-shop-hybrid](examples/online-shop-hybrid/) — the canonical end-to-end example (aggregates **and** DCB slices); runs locally in-memory and deploys to AWS
- [online-shop-aggregates](examples/online-shop-aggregates/), [online-shop-dcb](examples/online-shop-dcb/) — single-style variants

---

## 🚀 Getting Started

### Prerequisites

- **Node.js** v22.17.1 — see [`.node-version`](.node-version). [`fnm`](https://github.com/Schniz/fnm) / `nvm` will pick it up automatically.
- **pnpm** 10 — this repo enforces pnpm via `packageManager` + corepack. Enable with `corepack enable`. **Do not use `npm`.**
- **Git**.
- **OCaml toolchain (opam + dune)** — *only* if there is no prebuilt ReScript PPX binary for your platform (see [PPX binary](#ppx-binary) below). Prebuilt binaries cover Linux x64 and macOS arm64; other platforms build the PPX from source during setup.

### Quick start (clone → running example)

```bash
git clone <repo-url> reventless-core
cd reventless-core
corepack enable          # ensures the pinned pnpm version

pnpm run setup           # one-command bootstrap (see below)

# Run the hybrid example backend (GraphQL + MCP; SQLite stores by default,
# or `pnpm run serve:memory` for in-memory):
cd examples/online-shop-hybrid/platform-in-memory
pnpm run serve
```

Then log in to the **Domain GraphQL** server as `admin` / `admin`:

```bash
curl -s -X POST http://localhost:4000/__inmemory/login \
  -H 'content-type: application/json' \
  -d '{"username":"admin","password":"admin"}'
```

Endpoints once `serve` is running:

| Service | URL |
|---------|-----|
| Domain GraphQL (+ `/__inmemory/login`, `/sdl`) | http://localhost:4000/graphql |
| Platform GraphQL (+ graphql-ws subscriptions) | http://localhost:4001/graphql |
| Domain MCP | http://localhost:3001/mcp |
| Platform MCP | http://localhost:3002/mcp |

See [examples/online-shop-hybrid/README.md](examples/online-shop-hybrid/README.md) for the full example (including the host-shell UI via `pnpm run dev:full`) and AWS deployment.

### What `pnpm run setup` does

[`scripts/setup.mjs`](scripts/setup.mjs) is idempotent and runs, in order:

1. **Creates `pnpm-workspace.yaml`** — it is gitignored (a symlink to [`pnpm-workspace.base.yaml`](pnpm-workspace.base.yaml), so the cross-repo dev overlay used by `pnpm link:on` / `link:off` can swap it). A fresh clone has none, so plain `pnpm install` would fail with `ERR_PNPM_WORKSPACE_PKG_NOT_FOUND`. (Manual equivalent: `node scripts/workspace-setup.mjs`.)
2. **`pnpm install`** — from the repo root.
3. **Ensures the ReScript PPX binary** for your platform (prebuilt, or built from source — see below).
4. **Seeds `examples/.../platform-in-memory/.reventless/users.yaml`** from the committed `users.example.yaml` so local login works (`admin`/`admin`, `user`/`user`).
5. **Builds** the hybrid in-memory example (skip with `pnpm run setup --no-build`).

To build everything instead of just the example: `pnpm run build`. To run the full test suite: `pnpm test`.

### PPX binary

Reventless uses a native ReScript PPX (`@reventlessdev/reventless-ppx`). Prebuilt per-platform binaries exist for **Linux x64**, **macOS arm64**, and **macOS x64** — but they live on a **private GitHub Packages registry**, so installing them needs a GitHub token with `read:packages` (set `GITHUB_TOKEN` in your environment; see [.npmrc](.npmrc)).

**Without a token, or on a platform with no prebuilt (e.g. Linux arm64), `pnpm run setup` automatically builds the PPX from source** via `opam exec -- dune build` — this is the zero-config path and just needs the OCaml toolchain installed. Manual build:

```bash
(cd packages/reventless-ppx/src && opam exec -- dune build)
cp packages/reventless-ppx/src/_build/default/bin/bin.exe \
   packages/reventless-ppx/ppx-osx-x64.exe   # name depends on platform; see packages/reventless-ppx/bin
```

> **Windows:** build and run inside **WSL2** (it presents as Linux x64); there is no native Windows binary.

For detailed development workflow and contributing guidelines, see [CONTRIBUTING.md](CONTRIBUTING.md).

## 📚 Documentation

Full documentation is a [Docusaurus](https://docusaurus.io) site under [`packages/doc/`](packages/doc/). To run it locally:

```bash
pnpm --filter ./packages/doc run start   # dev server with hot reload
```

See [CLAUDE.md](CLAUDE.md) for build commands and an architecture overview.

## 🔗 Related Repositories

- **reventless-ui** — a companion React component/UI library for Reventless applications, distributed separately. It consumes `rescript-moment` from this repo.

## 🏗️ Architecture

Reventless is an event-sourced CQRS framework designed for serverless infrastructure, written in ReScript.

### Package Hierarchy

```
reventless-spec (foundation)
  ↓
reventless (core framework + all bindings)
  ↓
reventless-aws (AWS adapters)
```

### Key Components

- **Aggregate** - Event-sourced aggregate root with CommandTopic, EventLog, CommandGenerator
- **ReadModel** - Query-side projection consuming events via EventCollector
- **Plugin** - Deployable unit containing aggregates, read models, extension points
- **Core** - Application core orchestrating all components

### Adapter Pattern

The framework separates deploy-time (Pulumi infrastructure) from runtime (Lambda handlers):
- `src/adapter/` - Deploy-time adapter interfaces
- `src/adapter/Runtime/` - Runtime builders (Single, PerAggregate, Micro)

AWS adapters implement:
- EventLog storage → DynamoDB
- CommandTopic/EventTopic channels → SQS (FIFO), SNS
- QueryDb → DynamoDB
- Task buckets → S3

## 📄 License

Reventless is licensed under the [Apache License 2.0](LICENSE).

## 📜 Provenance

Reventless was originally developed (2019–2025) by Atos Austria GmbH /
Eviden Austria GmbH and used in production before its open-source release.
The intellectual-property rights were subsequently transferred to Martin
Lorenz, who released it under the Apache License 2.0 in 2026.
See [NOTICE](NOTICE) for original-author attribution.

## Contributing

We welcome contributions! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for detailed guidelines on:

- Setting up your development environment
- Making changes and submitting pull requests
- Commit message conventions (Conventional Commits)
- Package management with Lerna
- Publishing packages to GitHub Registry

For release process documentation, see [RELEASE.md](RELEASE.md).

