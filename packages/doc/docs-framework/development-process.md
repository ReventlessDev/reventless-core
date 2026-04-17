---
title: Development Process
date: 2026-02-13
draft: false
sidebar_position: 3
---

# Development Process

This guide describes the development workflow, branching strategy, and release process for the Reventless project.

## Overview

Reventless uses a multi-stage branching strategy with automated releases. Code progresses through three levels of stability:

1. **Alpha** - Early development and rapid iteration
2. **Beta** - Broader testing before production
3. **Main** - Production-ready stable releases

All releases are automated using [Lerna](https://lerna.js.org/) and follow [Semantic Versioning](https://semver.org/) based on [Conventional Commits](https://conventionalcommits.org).

## Branch Structure

| Branch | Release Type | Example Version | Protection | Purpose |
|--------|--------------|-----------------|------------|---------|
| **alpha** | Alpha pre-release | `1.2.0-alpha.1` | Direct pushes allowed | Early testing, rapid iteration, experimental features |
| **beta** | Beta pre-release | `1.2.0-beta.1` | Requires PR reviews | Testing before production, more stable than alpha |
| **main** | Production | `1.2.3` | Requires PR reviews + passing CI | Stable releases for production use |

## Development Workflow

### 1. Starting New Work

Create a feature branch from your starting point:

```bash
# For new features
git checkout -b feature/my-feature

# For bug fixes
git checkout -b fix/bug-description

# For refactoring
git checkout -b refactor/component-name
```

### 2. Making Changes

Follow the commit message conventions:

```bash
# New feature (minor version bump)
git commit -m "feat: add user authentication"

# Bug fix (patch version bump)
git commit -m "fix: resolve memory leak in event handler"

# Breaking change (major version bump)
git commit -m "feat!: redesign API interface

BREAKING CHANGE: API endpoints now require authentication tokens"

# No version bump
git commit -m "docs: update README"
git commit -m "test: add unit tests for aggregate"
git commit -m "chore: update dependencies"
```

#### Commit Type Reference

| Type | Version Bump | Description |
|------|--------------|-------------|
| `feat:` | Minor (0.X.0) | New feature |
| `fix:` | Patch (0.0.X) | Bug fix |
| `perf:` | Patch (0.0.X) | Performance improvement |
| `refactor:` | Patch (0.0.X) | Code refactoring |
| `feat!:` or `BREAKING CHANGE:` | Major (X.0.0) | Breaking change |
| `docs:` | None | Documentation only |
| `test:` | None | Test updates |
| `chore:` | None | Build process or tooling |
| `ci:` | None | CI configuration |
| `style:` | None | Code style/formatting |

#### Dependency Update Conventions

Use the appropriate commit type based on the **impact** of the dependency update:

**Include in CHANGELOG (`fix:` or `feat:`):**

```bash
# Security updates - ALWAYS use fix:
git commit -m "fix(deps): update package-x to address CVE-2024-xxxxx"

# Bug fixes via dependencies
git commit -m "fix(deps): update aws-sdk to fix S3 multipart upload issue"

# Breaking changes (triggers major version bump)
git commit -m "feat(deps)!: upgrade rescript to v12

BREAKING CHANGE: ReScript v12 requires migration of pattern matching syntax"

# New features from dependencies
git commit -m "feat(deps): add new aws-sdk feature for improved performance"
```

**Exclude from CHANGELOG (`chore:`):**

```bash
# Routine patch updates with no functional impact
git commit -m "chore(deps): update dev dependencies to latest patches"

# Build tooling updates
git commit -m "chore(deps): update lerna to v8.2.5"
```

**Key principle:** If a dependency change affects users, fixes a bug, adds a feature, or has security implications, use `fix:` or `feat:` so it appears in the CHANGELOG. Use `chore:` only for routine maintenance updates.

### 3. Testing Locally

Before pushing, ensure your changes work:

```bash
# Install dependencies (if package.json changed)
npm install

# Build all packages
npm run build

# Run tests
npm run test

# Test specific package
cd packages/reventless
npm run test
```

### 4. Branch Promotion Flow

The typical flow is: **feature → alpha → beta → main**

#### Merge to Alpha

Use alpha for early testing and rapid iteration:

```bash
git checkout alpha
git merge feature/my-feature
git push origin alpha
```

What happens:
- ✅ CI runs (type check, build, tests)
- ✅ Creates alpha version: `1.2.0-alpha.1`
- ✅ Publishes to GitHub Package Registry
- ✅ Creates GitHub release (marked as pre-release)

#### Merge to Beta

After alpha testing, promote to beta:

```bash
git checkout beta
git merge alpha
git push origin beta
```

What happens:
- ✅ CI runs (type check, build, tests)
- ✅ Creates beta version: `1.2.0-beta.1`
- ✅ Publishes to GitHub Package Registry
- ✅ Creates GitHub release (marked as pre-release)

#### Merge to Main

After beta validation, promote to production:

```bash
git checkout main
git merge beta
git push origin main
```

What happens:
- ✅ CI runs (type check, build, tests)
- ✅ Creates stable version: `1.2.0`
- ✅ Publishes to GitHub Package Registry
- ✅ Creates GitHub release (stable)

## When to Transition Between Branches

### Alpha → Beta

Promote to beta when:
- Feature is functionally complete
- Initial testing in alpha passed
- No critical bugs
- Ready for broader testing

### Beta → Main

Promote to main when:
- All testing passed in beta
- Feature is stable and production-ready
- Documentation is complete and updated
- Breaking changes are documented with migration guides
- Performance testing complete (if applicable)

## CI/CD Pipeline

### Continuous Integration (`ci.yml`)

Runs on **ALL branches** (including feature branches):

1. **Type Check & Build**
   - Validates ReScript compilation
   - Builds all packages
   - Caches build artifacts

2. **Test Suite**
   - Runs unit tests across all packages
   - Runs integration tests
   - Reports test results

The CI must pass before the release workflow can proceed.

### Release Workflow (`release.yml`)

Runs only on **main, beta, alpha** branches:

1. **Wait for CI** - Ensures all tests pass
2. **Determine Release Type** - Based on branch (stable, beta, alpha)
3. **Analyze Commits** - Using Conventional Commits
4. **Version Packages** - Lerna calculates new versions
5. **Update CHANGELOGs** - Generate changelog entries
6. **Build Packages** - Clean build of all packages
7. **Publish Packages** - To GitHub Package Registry
8. **Create Git Tags** - Tag each versioned package
9. **Push Changes** - Tags and changelog updates
10. **Create GitHub Releases** - With auto-generated release notes

## Version Numbering Examples

| Current Version | Commit Type | Branch | Next Version |
|-----------------|-------------|--------|--------------|
| `1.0.0` | `feat:` | main | `1.1.0` |
| `1.0.0` | `fix:` | main | `1.0.1` |
| `1.0.0` | `feat!:` | main | `2.0.0` |
| `1.2.3` | `feat:` | alpha | `1.3.0-alpha.1` |
| `1.3.0-alpha.1` | `fix:` | alpha | `1.3.0-alpha.2` |
| `1.3.0-alpha.2` | `feat:` | beta | `1.3.0-beta.1` |
| `1.3.0-beta.1` | - | main | `1.3.0` (graduated) |

## Best Practices

### Do's

✅ **Follow Conventional Commits** - This drives automated versioning<br/>
✅ **Test locally first** - Run build and tests before pushing<br/>
✅ **Keep commits focused** - One logical change per commit<br/>
✅ **Write clear commit messages** - Explain the "why", not just the "what"<br/>
✅ **Update package-lock.json** - Always run `npm install` after modifying `package.json`<br/>
✅ **Use feature branches** - Keep work isolated until ready<br/>
✅ **Progress through stages** - alpha → beta → main<br/>
✅ **Document breaking changes** - Use `BREAKING CHANGE:` in commit body

### Don'ts

❌ **Don't manually edit versions** - Let Lerna handle versioning<br/>
❌ **Don't skip testing** - Always ensure CI passes<br/>
❌ **Don't force push to protected branches** - Use proper merge workflow<br/>
❌ **Don't merge broken code** - Fix issues before promoting<br/>
❌ **Don't bypass stages** - Follow alpha → beta → main flow<br/>
❌ **Don't commit directly to main** - Use feature branches and PRs<br/>
❌ **Don't use generic commit messages** - "fix stuff" doesn't help automation

## Working with the Monorepo

### Installing Dependencies

```bash
# Install all dependencies for all packages
npm install

# Install for specific package
cd packages/reventless
npm install
```

**Important:** Always commit both `package.json` and `package-lock.json` together. The CI uses `npm ci` which requires them to be in sync.

### Building Packages

```bash
# Build all packages
npm run build

# Build specific package (from root)
npm run build --workspace=@reventlessdev/reventless

# Build specific package (from package directory)
cd packages/reventless
npm run build

# Watch mode for development
cd packages/reventless
npm run start
```

### Running Tests

```bash
# Run all tests
npm run test

# Test specific package
cd packages/reventless
npm run test

# Watch mode
cd packages/reventless
npm run dev

# Run single test file
cd packages/reventless
npx jest tests/MessageTest.res.js
```

### Cleaning Build Artifacts

```bash
# Clean all packages
npm run clean

# Clean and rebuild
npm run clean && npm run build
```

## Troubleshooting

### CI Fails with "package-lock.json out of sync"

**Problem:** You modified `package.json` but didn't update `package-lock.json`

**Solution:**
```bash
npm install
git add package.json package-lock.json
git commit -m "fix(deps): synchronize package-lock.json"
```

### Release Workflow Doesn't Create a Version

**Possible causes:**

1. **No releasable commits** - Only `chore:`, `docs:`, or `test:` commits since last release
   - Solution: Ensure you have `feat:` or `fix:` commits

2. **Wrong branch** - Pushing to feature branch instead of alpha/beta/main
   - Solution: Merge to appropriate release branch

3. **CI failed** - Release waits for CI to pass
   - Solution: Fix test failures and push again

### Version Number Seems Wrong

**Problem:** Expected version doesn't match what was created

**Causes:**
- Commit messages don't follow Conventional Commits format
- Breaking change not properly marked with `!` or `BREAKING CHANGE:`
- Commits were squashed and message was lost

**Solution:** Review commit messages and follow the format exactly

### Merge Conflicts During Branch Promotion

**Problem:** Conflicts when merging alpha → beta or beta → main

**Solution:**
```bash
git checkout beta
git merge alpha
# Resolve conflicts in your editor
git add .
git commit -m "chore: merge alpha into beta"
git push origin beta
```

## Additional Resources

- `RELEASE.md` - Detailed release process documentation
- `CONTRIBUTING.md` - Contribution guidelines
- [Conventional Commits Specification](https://conventionalcommits.org/)
- [Semantic Versioning](https://semver.org/)
- [Lerna Documentation](https://lerna.js.org/)

## Quick Reference

```bash
# Feature Development Flow
git checkout -b feature/my-feature
# ... make changes ...
git commit -m "feat: add new feature"
git push origin feature/my-feature

# Alpha Testing
git checkout alpha
git merge feature/my-feature
git push origin alpha
# → Creates 1.2.0-alpha.1

# Beta Testing
git checkout beta
git merge alpha
git push origin beta
# → Creates 1.2.0-beta.1

# Production Release
git checkout main
git merge beta
git push origin main
# → Creates 1.2.0

# Check CI Status
# Visit: https://github.com/ReventlessDev/reventless-core/actions

# View Releases
# Visit: https://github.com/ReventlessDev/reventless-core/releases
```
