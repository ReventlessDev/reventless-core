# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Context

This is **reventless-core** - one of two split monorepos:
- **This repo (core)**: Framework core, AWS adapters, ReScript bindings (16 packages)
- **Related repo (UI)**: [reventless-ui](https://github.com/yourorg/reventless-ui) - React components (2 packages)

The UI repo depends on `rescript-moment` from this repo via file reference, requiring both repos to be co-located.

## Monorepo Folder Structure

This is a Lerna monorepo. Packages are organized by type — **always place new packages in the correct root folder**:

| Folder | Purpose | Examples |
|--------|---------|---------|
| `rescript/` | ReScript bindings for JS/npm libraries | `rescript-uuid`, `rescript-graphql-yoga` |
| `reventless/` | Reventless framework + extension packages | `reventless-spec`, `reventless-in-memory` |
| `examples/` | Example applications | `examples/online-shop-aggregates/`, `examples/online-shop-dcb/`. Codegen-generated examples live under `examples/codegen/<adapter>/<fixture-stem>/` and are diffed against `reventless-codegen` test fixtures by `ForwardGoldenTest.res`. |
| `packages/` | Build tooling and documentation only | `doc` |

All four folders are Lerna workspaces (`lerna.json` packages) and pnpm workspaces (declared in `pnpm-workspace.yaml`).

## Build Commands

Use Node v22.17.1 (specified in `.node-version`) and pnpm 10 (enforced via `packageManager` + `corepack`). See [docs/guides/pnpm-guide.md](docs/guides/pnpm-guide.md) for an npm→pnpm reference.

### Monorepo-level commands
```bash
pnpm install                   # Install root dependencies
pnpm run build                 # Build all packages
pnpm test                      # Run tests in all packages
pnpm run clean                 # Clean all packages
```

### Per-package commands (run from the package directory, e.g. `reventless/reventless-in-memory/`)
```bash
pnpm run build                 # rescript build
pnpm run start                 # rescript build -w (watch mode)
pnpm run rebuild               # clean + build with dependencies
pnpm test                      # jest
pnpm run dev                   # jest --watchAll
```

### Running a single test file
```bash
cd reventless/reventless && pnpm exec jest tests/MessageTest.res.mjs
```

### Publishing
```bash
pnpm exec lerna publish        # Version and publish all changed packages
pnpm exec lerna version        # Version only without publishing
```

## Commit Message Conventions

This project uses [Conventional Commits](https://conventionalcommits.org) for automated versioning and changelog generation via Lerna.

### Dependency Updates

Categorize dependency updates based on their **impact** to determine changelog visibility:

**Include in changelog (`fix:` or `feat:`):**
```bash
# Security updates - ALWAYS include
fix(deps): update package-x to address CVE-2024-xxxxx

# Bug fixes via dependencies
fix(deps): update aws-sdk to fix S3 multipart upload issue

# Breaking changes (triggers major version bump)
feat(deps)!: upgrade rescript to v12 (breaking change)

# New features from dependencies
feat(deps): add new aws-sdk feature for improved performance
```

**Exclude from changelog (`chore:`):**
```bash
# Routine patch updates with no functional impact
chore(deps): update dev dependencies to latest patches

# Build tooling updates
chore(deps): update lerna to v8.2.5
```

**Key principle:** If a dependency change affects users, fixes a bug, adds a feature, or has security implications, use `fix:` or `feat:` so it appears in the CHANGELOG. Use `chore:` only for routine maintenance updates.

## Architecture

Reventless is an **event-sourced CQRS framework** for serverless infrastructure, written in **ReScript** (formerly ReasonML/BuckleScript).

### Package Hierarchy

1. **reventless-spec** - Type specifications and interfaces (defines aggregate, read model, plugin specs)
2. **reventless** - Core framework (provider-agnostic components and adapters)
3. **reventless-aws** - AWS-specific implementations (DynamoDB, Lambda, SQS, SNS, S3 adapters)
4. **rescript-*** - ReScript bindings for various JS libraries (aws-sdk, pulumi, uuid, etc.)

### Core Components (in `reventless/reventless-core/src/components/`)

- **Aggregate** - Event-sourced aggregate root with CommandTopic, EventLog, CommandGenerator
- **ReadModel** - Query-side projection consuming events via EventCollector
- **Plugin** - Deployable unit containing aggregates, read models, extension points
- **Platform_Admin** (in `src/admin/`) - Built-in platform components (Plugin aggregate, read model, extension point, cloner)

Component structure pattern (documented in `packages/doc/docs-framework/inner-workings/component-structure-pattern.md`):

**Core Files (Required):**
- `Component.res` - Type definitions and outputs
- `Component_Builder.res` - Factory for creating components using functors

**Optional Files:**
- `Component_Adapter.res` - Provider-agnostic adapter interface for infrastructure dependencies
- `Component_Operations.res` - Runtime business logic implementation (type-safe operations)
- `Component_Callback.res` - Runtime handlers (where applicable)

See the documentation for detailed explanations and examples using EventLog as a complete example.

### Plugin Composition Roots

Plugin packages (`examples/*/catalog/`, `examples/*/ordering/`, etc.) contain a **generated** composition root at `src/Plugin.res`. This file is produced by `generate-plugin` (from `reventless-spec`) before each build:

- `prebuild` script runs `generate-plugin src/` automatically before `rescript build`
- `src/plugin.json` (optional) sets the plugin name and heartbeat interval
- The generator scans `src/` by folder name (e.g. `Aggregate/`, `StateChangeSlice/`) and wires all discovered components
- `src/Plugin.res` is committed to git — CI compiles it directly without re-running the generator

Plugin modules are referenced from the platform as `<Namespace>.Plugin.Make(Platform)` (e.g. `CatalogPlugin.Plugin.Make(Platform)`).

**Convention:** Each `Extension/` file exposes its mapping as `module Mapping` (not a descriptively named variant). The generator references it as `ExtensionFile.Mapping`.

### Adapter Pattern

The framework separates **deploy-time** (Pulumi infrastructure) from **runtime** (Lambda handlers):
- `src/adapter/` - Deploy-time adapter interfaces
- `src/adapter/Runtime/` - Runtime builders for different deployment strategies (Single, PerAggregate, Micro)

AWS adapters in `reventless/reventless-aws/src/adapter/` implement:
- EventLog storage → DynamoDB
- CommandTopic/EventTopic channels → SQS (FIFO), SNS
- QueryDb → DynamoDB
- Task buckets → S3

### Key Patterns

**Builder pattern with module types**: Components use first-class modules for type-safe configuration
```rescript
module type T = {
  module Spec: Reventless.Aggregate.Spec
  let make: (~opts: Pulumi.ComponentResource.options=?) => component
}
```

**Pulumi.Output.t wrapping**: All infrastructure values are wrapped in `Pulumi.Output.t<'a>` for deploy-time/runtime separation

**sury-ppx**: Uses the `@schema` attribute for automatic JSON serialization via sury

### ReScript Configuration

Packages use `rescript.json` with:
- `sury-ppx/bin` PPX for schema generation
- `-open RescriptCore` flag
- CommonJS output with `.res.js` suffix

### ReScript LSP

A ReScript language server plugin is configured for Claude Code, providing type-aware code intelligence for `.res` and `.resi` files:
- **hover**: Full type signatures with expanded type definitions
- **goToDefinition**: Cross-file symbol resolution within the monorepo
- **findReferences**: Find all usages of a symbol
- **documentSymbol**: List all symbols in a file

Prerequisite: `pnpm add -g @rescript/language-server` (v1.72.0+). The plugin lives at `~/.claude/plugins/marketplaces/claude-code-lsps/rescript-lsp/`.

Not supported by the ReScript LSP: `workspaceSymbol`, `goToImplementation`, `callHierarchy`.

## Documentation

The `packages/doc/` directory contains a Docusaurus-based documentation site.

### Running the docs locally
```bash
pnpm --filter ./packages/doc install
pnpm --filter ./packages/doc run start   # Start dev server with hot reload
pnpm --filter ./packages/doc run build   # Build static site
pnpm --filter ./packages/doc run serve   # Serve built site
```

### Documentation Structure (`packages/doc/docs/`)

- **index.md** - Introduction to Reventless (methodology, programming model, framework overview)
- **get-started.md** - Getting started guide
- **advanced.md** - Advanced usage scenarios
- **rescript-syntax.md** - ReScript language reference
- **reventless-components-overview.md** - High-level component overview with diagrams
- **reventless-component-relations.md** - How components interact
- **reventless-components/** - Detailed docs for each component:
  - aggregate.md, readmodel.md, plugin.md, extensionpoint.md, extension.md, task.md, api.md
- **reventless-common-modules/** - Shared module docs (Id, config, counter)
- **inner-workings/** - Framework internals:
  - framework-inner-workings.md, messages.md, pulumi.md, aws-lambda.md, resources.md, serialization.md
- **troubleshooting/** - Common issues and solutions

## Code Smells to Avoid

From the codebase documentation:
- `...->ignore` in ReScript
- `...->Pulumi.Output.apply(_, ...)` - prefer piped version
- `option(Pulumi.Output.t('a))` - this type combination doesn't work correctly

## Packages in This Repo

**`reventless/` — Framework packages:**
- `reventless-spec` — type specifications and interfaces
- `reventless` — core framework (provider-agnostic)
- `reventless-aws` — AWS adapters (DynamoDB, Lambda, SQS, SNS, S3)
- `reventless-in-memory` — in-memory platform for local dev and testing
- `reventless-interop` — JS interop helpers
- `reventless-layer-builder` — Lambda layer builder (private)

**`rescript/` — ReScript bindings:**
- `rescript-aws-sdk`, `rescript-pulumi-pulumi`, `rescript-pulumi-aws`
- `rescript-uuid`, `rescript-fast-csv`, `rescript-hash-object`
- `rescript-node-streams`, `rescript-node-zlib`, `rescript-ssh2`
- `rescript-graphql-yoga` — bindings for graphql-yoga v5
- `rescript-moment` (shared with UI repo via file reference)

**`examples/` — Example applications:**
- `examples/online-shop-aggregates/` — aggregate-based plugin examples
- `examples/online-shop-dcb/` — DCB-based plugin examples

**`packages/` — Build tooling and documentation:**
- `doc` — Docusaurus documentation site

**Packages in UI Repo (separate repository):**
- `reventless-ui`, `routes`

The UI repo references `rescript-moment` from this repo using: `"file:../../../reventless-core/rescript/rescript-moment"`

## Repo conventions

### `.res.mjs` tracking

Most ReScript packages here use `package-specs.in-source: true`, so compiled `.res.mjs` files land alongside `.res` sources. The convention is:

- **Tracked**: outputs under `src/` and per-package `tests/` (where applicable). Either a publish-surface deliverable, shared workspace state run by CI, or — for monorepo `examples/` apps — the entry point that Pulumi (`Main.res.mjs`) and `pnpm run run` (`Main.res.mjs` + transitive `Plugin.res.mjs` etc.) resolve at runtime. ReScript only emits in-source for build-root packages, so transitively-built deps don't reliably populate `src/` on a fresh `pnpm run build`; tracking the outputs avoids per-package build orchestration.
- **Not tracked**: outputs under `rescript/*/src/example/` and `rescript/*/src/examples/` — inline usage demos inside ReScript binding packages (e.g. `rescript-aws-sdk/src/example`, `rescript-uuid/src/examples`). These regenerate on every build and aren't part of any publish surface or deploy path.

Per-package `.gitignore` files (like `rescript/rescript-effect/.gitignore` covering its own `tests/`) remain as local exceptions where needed.
