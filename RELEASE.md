# Release Process

This document describes how releases are made in the Reventless project.

## Table of Contents

- [Overview](#overview)
- [Automated Releases](#automated-releases)
- [Release Branches](#release-branches)
- [Version Bumping](#version-bumping)
- [Manual Releases](#manual-releases)
- [Pre-release Versions](#pre-release-versions)
- [Release Checklist](#release-checklist)
- [CI/CD Integration](#cicd-integration)
- [Troubleshooting](#troubleshooting)

## Overview

This project uses [semantic-release](https://semantic-release.gitbook.io/) for automated versioning and publishing. The release process is triggered automatically when commits are pushed to specific branches.

## Automated Releases

When commits are pushed to release branches, semantic-release will automatically:

1. Analyze commits since the last release using [Conventional Commits](https://www.conventionalcommits.org/)
2. Determine the next version number based on commit types
3. Generate or update the `CHANGELOG.md`
4. Create a Git tag with the new version
5. Publish packages to the npm registry
6. Create a GitHub release with generated release notes

### Commit Analysis

The project uses the following commit types to determine version bumps:

| Commit Type | Version Bump | Description |
|-------------|--------------|-------------|
| `feat` | Minor | New features |
| `fix` | Patch | Bug fixes |
| `perf` | Patch | Performance improvements |
| `refactor` | Patch | Code refactoring |
| `build` | Patch | Build system changes |
| `docs` (README scope) | Patch | Documentation updates |
| `revert` | Patch | Reverted changes |
| `test` | None | Test additions/updates |
| `ci` | None | CI/CD changes |
| `style` | None | Code style changes |
| `BREAKING CHANGE:` | Major | Breaking changes (in commit footer) |

## Release Branches

| Branch | Release Type | Example Version | Use Case |
|--------|--------------|-----------------|----------|
| `main` | Production | `1.2.3` | Stable releases for production use |
| `beta` | Beta pre-release | `1.2.0-beta.1` | Testing before production release |
| `alpha` | Alpha pre-release | `1.2.0-alpha.1` | Early testing and development |

### Branch Protection

- `main`: Requires pull request reviews and passing CI checks
- `beta`: Requires pull request reviews
- `alpha`: Can accept direct pushes for rapid iteration

## Version Bumping

### Semantic Versioning

This project follows [Semantic Versioning](https://semver.org/) (SemVer):

- **Major** (X.0.0): Breaking changes that require user action
- **Minor** (x.Y.0): New features that are backward compatible
- **Patch** (x.y.Z): Bug fixes and improvements that are backward compatible

### Version Bump Examples

| Current | Commit Type | Next Version |
|---------|-------------|--------------|
| 1.0.0 | `feat: add new feature` | 1.1.0 |
| 1.0.0 | `fix: resolve bug` | 1.0.1 |
| 1.0.0 | `feat: new feature` + `BREAKING CHANGE:` | 2.0.0 |
| 1.2.3-beta.1 | `fix: bug fix` | 1.2.3-beta.2 |

## Manual Releases

While automated releases are preferred, you can perform manual releases using Lerna:

### Version Only

Update version numbers without publishing:

```bash
npx lerna version
```

This will:
- Detect changed packages since the last release
- Prompt for version bump type (patch/minor/major/prerelease)
- Update `package.json` files in all affected packages
- Create Git tags for each package
- Push changes to the remote repository

### Version and Publish

Combine versioning and publishing in one command:

```bash
npx lerna publish
```

### Publish Specific Package

To publish a single package:

```bash
cd packages/<package-name>
npm publish
```

### Force Publish

To republish packages (use with caution):

```bash
npx lerna publish --force-publish
```

## Pre-release Versions

### Creating Pre-releases

For beta releases:

```bash
npx lerna version prerelease --preid beta
```

For alpha releases:

```bash
npx lerna version prerelease --preid alpha
```

### Promoting Pre-releases

To promote a pre-release to a stable version:

```bash
npx lerna version [patch|minor|major]
```

### Pre-release Workflow Example

1. Create a feature branch from `main`:
   ```bash
   git checkout -b feature/new-feature
   ```

2. Make changes and commit using Conventional Commits

3. Merge to `alpha` for initial testing:
   ```bash
   git checkout alpha
   git merge feature/new-feature
   git push origin alpha
   # Creates: 1.1.0-alpha.1
   ```

4. Merge to `beta` for broader testing:
   ```bash
   git checkout beta
   git merge alpha
   git push origin beta
   # Creates: 1.1.0-beta.1
   ```

5. Merge to `main` for production:
   ```bash
   git checkout main
   git merge beta
   git push origin main
   # Creates: 1.1.0
   ```

## Release Checklist

Before making a release, ensure:

- [ ] All tests pass locally and in CI
- [ ] Documentation is up to date
- [ ] CHANGELOG entries are meaningful and complete
- [ ] Breaking changes are clearly documented with migration guide
- [ ] Version numbers follow semantic versioning
- [ ] No `console.log` statements or debug code in production files
- [ ] All dependencies are up to date (run `npm audit`)
- [ ] Package exports are correct and complete

## CI/CD Integration

### Automated Release Trigger

The release process runs automatically in CI/CD when:
- Commits are pushed to `main`, `beta`, or `alpha` branches
- All tests and quality checks pass
- Proper authentication tokens are configured

### Required Environment Variables

Configure these in your CI/CD environment:

| Variable | Purpose | Required For |
|----------|---------|--------------|
| `NPM_TOKEN` | Publishing to npm registry | Publishing packages |
| `GITHUB_TOKEN` | Creating GitHub releases | Required for releases |
| `GIT_AUTHOR_NAME` | Git commit author name | Automated commits |
| `GIT_AUTHOR_EMAIL` | Git commit author email | Automated commits |

### CI/CD Configuration

The release configuration is defined in [`.releaserc.json`](.releaserc.json):

- Uses `conventionalcommits` preset for commit analysis
- Generates release notes automatically
- Updates `CHANGELOG.md` files
- Publishes to npm registry
- Creates GitHub releases
- Commits version bumps back to repository

### Release Plugins

The following semantic-release plugins are used:

1. **@semantic-release/commit-analyzer**: Analyzes commits to determine version bump
2. **@semantic-release/release-notes-generator**: Generates release notes
3. **@semantic-release/changelog**: Updates CHANGELOG.md
4. **@semantic-release/npm**: Publishes to npm registry
5. **@semantic-release/github**: Creates GitHub releases
6. **@semantic-release/git**: Commits version changes

## Troubleshooting

### Release Failed

If a release fails:

1. Check CI/CD logs for error messages
2. Verify all environment variables are set correctly
3. Ensure the `NPM_TOKEN` has publish permissions
4. Check that the Git token has `repo` and `write:packages` scopes

### Version Not Bumped

If semantic-release doesn't create a new version:

1. Verify commits follow Conventional Commits format
2. Check that commits are on a release branch (`main`, `beta`, `alpha`)
3. Ensure there are new commits since the last release
4. Check the `.releaserc.json` configuration

### Recovering from Failed Release

If a release partially fails:

1. Fix the underlying issue
2. Push a new commit (can be a `chore` type to trigger re-analysis)
3. semantic-release will retry on the next push

### Manual Recovery

In extreme cases, you may need to:

1. Delete the Git tag locally and remotely:
   ```bash
   git tag -d v1.2.3
   git push --delete origin v1.2.3
   ```

2. Reset the version in `package.json` files

3. Push a fix commit and let semantic-release retry

## Additional Resources

- [semantic-release Documentation](https://semantic-release.gitbook.io/)
- [Conventional Commits Specification](https://www.conventionalcommits.org/)
- [Semantic Versioning Specification](https://semver.org/)
- [Lerna Documentation](https://lerna.js.org/)
