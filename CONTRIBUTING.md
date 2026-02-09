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
   cd reventless
   ```

3. **Set Up Development Environment**
   
   Follow the [Setup instructions in README.md](README.md#setup).

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
npm run build        # Build all packages
npm run watch        # Watch mode
npm run clean        # Clean all packages
npm run test         # Run tests
```

### Per-Package Commands

```bash
cd packages/<name>
npm run build        # rescript build
npm run start        # rescript build -w (watch mode)
npm run test         # jest
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
| `npm run watch` | Automatic rebuilds during development |
| `npm run clean` | Remove build artifacts |
| `npm run format` | Format code using ReScript formatter |
| `npm install` | Install dependencies (uses npm workspaces, `lerna bootstrap` not needed) |

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

For beta or alpha releases:

```bash
npx lerna version prerelease --preid beta
npx lerna version prerelease --preid alpha
```

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

### Common Release Commands

```bash
# Manual version bump
npx lerna version

# Version and publish
npx lerna publish

# Pre-release
npx lerna version prerelease --preid beta
```

See [RELEASE.md](RELEASE.md) for:
- Detailed release workflow
- Troubleshooting guide
- CI/CD configuration
- Pre-release promotion process
- Release checklist
- Environment variable setup

### Commit Types and Version Bumps

| Commit Type | Version Impact |
|-------------|----------------|
| `feat` | Minor (1.0.0 → 1.1.0) |
| `fix`, `perf`, `refactor`, `build` | Patch (1.0.0 → 1.0.1) |
| `BREAKING CHANGE:` | Major (1.0.0 → 2.0.0) |
| `test`, `ci`, `style` | No release |

## Publishing Packages

Packages in this monorepo are published to the GitHub Package Registry.

### Prerequisites

1. Create a Personal Access Token in GitHub Settings with the following privileges:
   - `repo` - Full control of private repositories
   - `write:packages` - Upload packages to GitHub Package Registry
   - `read:packages` - Download packages from GitHub Package Registry

2. Log in to the GitHub registry on your local machine:

   ```bash
   npm login --registry=https://npm.pkg.github.com --scope=@reventless-universe
   ```

   You will be prompted for:
   - **Username**: Your GitHub username
   - **Password**: Your Personal Access Token (not your GitHub password)
   - **Email**: Your public email address

### Installing Packages

After authentication, you can install packages:

```bash
npm install @reventless/<package-name>
```

### Publishing Packages

To publish a package:

```bash
# Navigate to the package directory
cd packages/<package-name>

# Publish to GitHub Registry
npm publish
```

Or use Lerna to publish all updated packages:

```bash
npx lerna publish
```

### Registry Configuration

The registry is configured in [`package.json`](package.json):

```json
{
  "publishConfig": {
    "@reventless:registry": "https://npm.pkg.github.com/"
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
