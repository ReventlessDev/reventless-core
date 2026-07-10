# Contributing to Reventless

Thank you for your interest in contributing to the Reventless framework! This document provides guidelines and instructions for contributing.

## Table of Contents

- [Getting Started](#getting-started)
- [Making Changes](#making-changes)
- [Commit Guidelines](#commit-guidelines)
- [Submitting Changes](#submitting-changes)
- [Development Workflow](#development-workflow)
- [Package Management with Lerna](#package-management-with-lerna)
- [Making Releases](#making-releases)
- [Publishing Packages](#publishing-packages)
- [Questions or Issues?](#questions-or-issues)

> **Note:** For detailed release process documentation, see [RELEASE.md](RELEASE.md). For project setup instructions, see [README.md](README.md).

## Getting Started

### Prerequisites

Before you begin, ensure you have:
- A GitHub account
- Node.js (see [`.node-version`](.node-version) for the required version)
- Git installed on your machine

### Fork and Clone

1. **Fork the Repository**
   
   Fork this repository to your own GitHub account.

2. **Clone Your Fork**

   ```bash
   git clone <your-fork-url>
   cd reventless-core
   ```

3. **Set Up Development Environment**

   This repo uses **pnpm** (not npm) and a one-command bootstrap:

   ```bash
   corepack enable      # pins the pnpm version from package.json
   pnpm run setup       # workspace symlink + install + PPX binary + example users + build
   ```

   See [Getting Started in README.md](README.md#-getting-started) for what each
   step does and platform-specific notes (e.g. the ReScript PPX binary).

4. **Create a Feature Branch**
   
   ```bash
   git checkout -b feature/your-feature-name
   ```
   
   Or for bug fixes:
   ```bash
   git checkout -b fix/your-bug-fix
   ```

## Code Standards

- Write clean, maintainable code
- Follow existing code style and conventions
- Add tests for new features
- Update documentation as needed

## 🛠️ Development

###  Commands (All Packages)

```bash
pnpm run build       # Build all packages
pnpm run watch       # Watch mode
pnpm run clean       # Clean all packages
pnpm test            # Run tests
```

### Per-Package Commands

```bash
cd reventless/<name>   # or rescript/<name>, examples/<app>/<pkg>, packages/<name>
pnpm run build         # rescript build
pnpm run start         # rescript build -w (watch mode)
pnpm test              # jest
```

## Commit Guidelines

This project uses [Conventional Commits](https://www.conventionalcommits.org/) for commit messages. This enables automatic versioning and changelog generation.

### Commit Message Format

```
<type>(<scope>): <subject>

<body>

<footer>
```

### Types

| Type | Description | Release Impact |
|------|-------------|----------------|
| `feat` | A new feature | Minor version bump |
| `fix` | A bug fix | Patch version bump |
| `perf` | Performance improvement | Patch version bump |
| `refactor` | Code refactoring | Patch version bump |
| `docs` | Documentation changes | Patch version bump (if README scope) |
| `test` | Adding or updating tests | No release |
| `build` | Build system changes | Patch version bump |
| `ci` | CI/CD changes | No release |
| `style` | Code style changes (formatting) | No release |
| `revert` | Reverting a previous commit | Patch version bump |

### Breaking Changes

Include `BREAKING CHANGE:` in the commit footer to trigger a major version bump.

### Examples

```bash
# Feature
feat(eventlog): add support for event filtering

# Bug fix
fix(aggregate): resolve race condition in state updates

# Documentation
docs(README): update setup instructions

# Breaking change
feat(api): add new endpoint for user management

BREAKING CHANGE: API endpoint structure has changed
```

### Special Scopes

- Use `no-release` scope to prevent a release: `feat(no-release): add internal tooling`

## Developer Certificate of Origin (DCO)

All contributions must be signed off under the
[Developer Certificate of Origin 1.1](https://developercertificate.org/). The
sign-off certifies that you wrote the contribution, or otherwise have the right to
submit it under the project's [Apache License 2.0](LICENSE).

Sign off every commit with the `-s` flag:

```bash
git commit -s -m "feat(eventlog): add support for event filtering"
```

This appends a trailer to the commit message using your Git author identity:

```
Signed-off-by: Your Name <your.email@example.com>
```

Use your real name and a reachable email. Pull requests whose commits are not
signed off cannot be merged.

## Submitting Changes

### Push Your Branch

```bash
git push origin feature/your-feature-name
```

### Create a Pull Request

1. Open a pull request against the `main` branch
2. Provide a clear description of your changes
3. Reference any related issues (e.g., "Fixes #123")
4. Ensure all CI checks pass

### Code Review

- Address any feedback from maintainers
- Make requested changes in new commits
- Push updates to your branch

## Development Workflow

### Useful Commands

| Command | Description |
|---------|-------------|
| `pnpm run setup` | One-command bootstrap for a fresh clone |
| `pnpm run watch` | Automatic rebuilds during development |
| `pnpm run clean` | Remove build artifacts |
| `pnpm run format` | Format code using ReScript formatter |
| `pnpm install` | Install dependencies (pnpm workspaces; needs `pnpm-workspace.yaml` — run `pnpm run setup` or `node scripts/workspace-setup.mjs` first on a fresh clone) |

## Package Management with Lerna

This project uses [Lerna 8.x](https://lerna.js.org/) to manage versioning and publishing across the monorepo, on top of **pnpm workspaces** (day-to-day dependency and linking is handled by pnpm, not Lerna). Run Lerna via `pnpm exec lerna`.

### Common Lerna Commands

| Command | Description |
|---------|-------------|
| `pnpm exec lerna ls` | List all packages in the monorepo |
| `pnpm exec lerna run <script>` | Run a package script in all packages that have it |
| `pnpm exec lerna exec <command>` | Run a command in all packages |

To remove build artifacts and `node_modules`, use `pnpm run clean` and `pnpm -r exec rm -rf node_modules` respectively.

### Creating a New Package

Packages are grouped into four workspace folders — **place a new package in the correct one** (see the [Packages table in the README](README.md#-packages)):

| Folder | For |
|--------|-----|
| `rescript/` | ReScript bindings for JS/npm libraries |
| `reventless/` | Framework + extension packages |
| `examples/` | Example applications |
| `packages/` | Build tooling and documentation only |

These are ReScript packages (each with a `rescript.json`), so the simplest path is to copy the closest existing sibling package into the right folder, rename it, and adjust its `package.json` / `rescript.json`. `pnpm install` then wires it into the workspace.

### Linking Local Packages

pnpm workspaces link local packages automatically. To depend on a local package `D` from another package `A`:

1. Add `D` to the `dependencies` in `A`'s `package.json` using the workspace protocol: `"@reventlessdev/D": "workspace:*"`
2. Run `pnpm install`

pnpm symlinks the workspace package so changes in `D` are immediately available in `A`. (For the cross-repo dev overlay used with the UI repo, see `pnpm run link:on` / `link:off`.)

### Versioning and Publishing

#### Version Packages

```bash
pnpm exec lerna version
```

This will:
- Detect changed packages since the last release
- Prompt for version bump (patch/minor/major/prerelease)
- Update `package.json` files
- Create Git tags
- Push changes to remote

#### Publish Packages

```bash
pnpm exec lerna publish
```

This combines versioning and publishing in one command. In practice publishing runs automatically in CI — see [Making Releases](#making-releases) and [RELEASE.md](RELEASE.md).

#### Pre-release Versions

```bash
pnpm exec lerna version prerelease --preid beta   # Beta release
pnpm exec lerna version prerelease --preid alpha  # Alpha release
```

For detailed pre-release workflow and branch strategy, see [RELEASE.md](RELEASE.md#pre-release-versions).

### Dependency Management

Dependencies are managed with **pnpm** (`lerna add` was removed in Lerna 7+):

```bash
# Add a dependency to a specific package
pnpm --filter <package-name> add <package>[@version]

# Add a dev dependency to the workspace root
pnpm add -w -D <package>[@version]

# Add a dependency to every package
pnpm -r add <package>[@version]
```

> **Note:** avoid running a bare `pnpm install` while the cross-repo dev overlay is active (`pnpm run link:status` to check) — it can pollute the lockfile. Use `pnpm run link:off` first.

## Making Releases

This project uses an automated release process. For complete documentation on the release process, see [RELEASE.md](RELEASE.md).

### Quick Summary

- Releases are automated using [semantic-release](https://semantic-release.gitbook.io/)
- Version bumps are determined by [Conventional Commits](#commit-guidelines)
- Release branches: `main` (production), `beta`, `alpha` (pre-releases)

See [RELEASE.md](RELEASE.md) for complete documentation on:
- Automated and manual release workflows
- Version bumping rules and examples
- Pre-release process (alpha/beta)
- Troubleshooting guide
- CI/CD configuration
- Release checklist

## Publishing Packages

Packages in this monorepo are published to the **public npm registry** (npmjs.com)
under the `@reventlessdev` scope.

### Installing Packages

`@reventlessdev/*` packages are public — installing needs **no authentication**:

```bash
npm install @reventlessdev/<package-name>
```

### Publishing Packages

Publishing is automated in CI (`release.yml`) via Lerna and authenticated with an
`NPM_TOKEN` org secret; scoped packages publish with `--access public`. Releases
flow through the branch pipeline (feature → alpha → beta → main) — see
[RELEASE.md](RELEASE.md). Manual publishing is not part of the normal workflow.

### Registry Configuration

`registry.npmjs.org` is the default registry, so packages need no
`publishConfig.registry` override. The publish registry and public access are set
once in [`lerna.json`](lerna.json):

```json
{
  "command": {
    "publish": {
      "registry": "https://registry.npmjs.org",
      "access": "public"
    }
  }
}
```

## Questions or Issues?

- **Bug Reports**: Open an issue with a clear description and reproduction steps
- **Feature Requests**: Open an issue describing the feature and its use case
- **Questions**: Open a discussion or reach out to maintainers

### Before Creating an Issue

1. Check existing issues to avoid duplicates
2. Provide detailed information:
   - Steps to reproduce (for bugs)
   - Expected vs actual behavior
   - Environment details (OS, Node version, etc.)
   - Relevant code snippets or error messages

## Code of Conduct

This project adheres to a code of conduct. By participating, you are expected to:

- Be respectful and inclusive
- Welcome newcomers
- Focus on constructive feedback
- Accept responsibility and apologize when mistakes are made

Thank you for contributing to Reventless!
