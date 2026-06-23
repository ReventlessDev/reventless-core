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

This project uses [Lerna 9.x](https://lerna.js.org/) to manage the monorepo. Lerna is a tool for managing JavaScript projects with multiple packages.

### Common Lerna Commands

| Command | Description |
|---------|-------------|
| `npx lerna ls` | List all packages in the monorepo |
| `npx lerna clean` | Remove `node_modules` from all packages |
| `npx lerna run <script>` | Run an npm script in all packages that have it |
| `npx lerna exec <command>` | Run a command in all packages |

### Creating a New Package

Use the `lerna create` command to scaffold a new package:

```bash
npx lerna create <package-name>
```

This will:
- Create a new directory in `./packages/`
- Bootstrap a `package.json` with appropriate defaults
- Set up the package structure

### Linking Local Packages

To use a local package (`D`) as a dependency in another package (`A`):

1. Add `D` to the `dependencies` in `package.json` of `A` (match the version)
2. Run `npm install` to link them

npm will create symlinks so changes in `D` are immediately available in `A`.

### Versioning and Publishing

#### Version Packages

```bash
npx lerna version
```

This will:
- Detect changed packages since the last release
- Prompt for version bump (patch/minor/major/prerelease)
- Update `package.json` files
- Create Git tags
- Push changes to remote

#### Publish Packages

```bash
npx lerna publish
```

This combines versioning and publishing in one command.

#### Pre-release Versions

```bash
npx lerna version prerelease --preid beta   # Beta release
npx lerna version prerelease --preid alpha  # Alpha release
```

For detailed pre-release workflow and branch strategy, see [RELEASE.md](RELEASE.md#pre-release-versions).

### Dependency Management

#### Add a Dependency to All Packages

```bash
npx lerna add <package>[@version]
```

#### Add a Dependency to a Specific Package

```bash
npx lerna add <package>[@version] --scope=<package-name>
```

#### Update Dependencies

Use the Lerna Update Wizard for bulk updates:

```bash
npm run update
```

Features:
- Update dependencies across packages
- Add new dependencies across packages
- Deduplicate dependencies
- Auto-generate Git branch & commit

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
