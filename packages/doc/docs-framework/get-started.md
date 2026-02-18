---
title: Contribution Setup
sidebar_position: 2
---

# Framework Contribution Setup

This guide covers setting up the development environment to contribute to `reventless-core`.

## Prerequisites

- **Node.js 22.17.1** — use [fnm](https://github.com/Schniz/fnm) or [nvm](https://github.com/nvm-sh/nvm) with the `.node-version` file in the repo root
- **Git**

## Clone and Install

```bash
git clone https://github.com/ReventlessDev/reventless-core.git
cd reventless-core
npm install
```

## Build All Packages

```bash
npm run build
```

This runs `rescript build` in each package via Lerna. ReScript compiles `.res` files to `.res.js` (CommonJS).

## Run Tests

```bash
npm test
```

Tests use Jest with `NODE_OPTIONS='--experimental-vm-modules'` for ESM compatibility. Test files match `*Test.res.mjs`.

To run a single package's tests:

```bash
cd packages/reventless
npm test
```

To run a single test file:

```bash
cd packages/reventless && npx jest tests/MessageTest.res.js
```

## Watch Mode

```bash
cd packages/reventless
npm run start   # rescript build -w
npm run dev     # jest --watchAll
```

## Branching and Commit Conventions

The repo uses [Conventional Commits](https://conventionalcommits.org) and semantic-release for automated versioning.

Branch flow: `feature/* → alpha → beta → main`

Commit format: `type(scope): description`

Common types: `feat`, `fix`, `chore`, `docs`, `refactor`, `test`

Examples:
```
feat(eventlog): add retry logic to append operations
fix(dcb): correct tag extraction for payload-less variants
chore(deps): update rescript to 11.1.4
```

## Package Structure

Each package in `packages/` has its own `rescript.json` and `package.json`. The key packages for framework development:

| Package | Purpose |
|---------|---------|
| `reventless-spec` | Shared type specs (no implementation) |
| `reventless` | Framework core — components, builders, adapter interfaces |
| `reventless-aws` | AWS adapter implementations |

## Adding a New Component

1. Create the component directory: `packages/reventless/src/components/MyComponent/`
2. Add `MyComponent.res` — type definitions
3. Add `MyComponent_Adapter.res` — adapter interfaces
4. Add `MyComponent_Builder.res` — the `Make` functor
5. Add `MyComponent_Operations.res` — runtime logic (if needed)
6. Add `MyComponent_Callback.res` — event/command handlers (if needed)
7. Expose the component from the package barrel file

See [Component Structure Pattern](./inner-workings/component-structure-pattern.md) for detailed guidance.

## Running the Docs

```bash
cd packages/doc
npm install
npm run start
```
