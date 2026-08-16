---
title: Development Process
sidebar_position: 3
---

# Development Process

The branching strategy, commit conventions, and automated release process for Reventless.
For environment setup, build, and test commands, see [Contributing](./contributing.md).

## Overview

Code progresses through three levels of stability, each an automated [Lerna](https://lerna.js.org/)
release that follows [Semantic Versioning](https://semver.org/) driven by
[Conventional Commits](https://conventionalcommits.org):

| Branch | Release Type | Example Version | Protection | Purpose |
|--------|--------------|-----------------|------------|---------|
| **alpha** | Alpha pre-release | `1.2.0-alpha.1` | Direct pushes allowed | Early testing, rapid iteration |
| **beta** | Beta pre-release | `1.2.0-beta.1` | Requires PR reviews | Broader testing before production |
| **main** | Production | `1.2.3` | Requires PR reviews + passing CI | Stable releases |

## Workflow

1. Branch off `alpha`: `feature/my-feature`, `fix/bug-description`, or `refactor/component-name`.
2. Make changes, keeping the build green (`pnpm run build`) and tests passing (`pnpm test`).
3. Commit with Conventional Commits (see below).
4. Promote through the stages: **feature → alpha → beta → main**.

```bash
git checkout alpha && git merge feature/my-feature && git push origin alpha   # → 1.2.0-alpha.1
git checkout beta  && git merge alpha                && git push origin beta   # → 1.2.0-beta.1
git checkout main  && git merge beta                 && git push origin main   # → 1.2.0
```

Each push to `alpha`/`beta`/`main` runs CI (type check, build, tests), then the release
workflow versions the changed packages, updates CHANGELOGs, publishes to the GitHub Package
Registry, and creates tagged GitHub releases (pre-release for alpha/beta).

**Promote alpha → beta** when the feature is functionally complete and alpha testing passed
with no critical bugs. **Promote beta → main** when testing passed, the feature is
production-ready, docs are updated, and any breaking changes carry migration guides.

## Commit Conventions

Commit messages drive automated versioning. This is the canonical reference; the
[Contributing](./contributing.md) guide summarizes it.

| Type | Version Bump | Description |
|------|--------------|-------------|
| `feat:` | Minor (0.X.0) | New feature |
| `fix:` | Patch (0.0.X) | Bug fix |
| `perf:` | Patch (0.0.X) | Performance improvement |
| `refactor:` | Patch (0.0.X) | Code refactoring |
| `feat!:` or `BREAKING CHANGE:` | Major (X.0.0) | Breaking change |
| `docs:` / `test:` / `chore:` / `ci:` / `style:` | None | No release |

Breaking changes use `!` and a `BREAKING CHANGE:` body:

```
feat!: redesign API interface

BREAKING CHANGE: API endpoints now require authentication tokens
```

### Dependency updates

Choose the type by **impact**, not by the fact that a version changed:

- `fix(deps):` / `feat(deps):` — security fixes, bug fixes, new features, or breaking changes
  (with `!`). These appear in the CHANGELOG.
- `chore(deps):` — routine patch updates with no user-facing impact. Excluded from the CHANGELOG.

```bash
git commit -m "fix(deps): update package-x to address CVE-2024-xxxxx"
git commit -m "feat(deps)!: upgrade rescript to v12"
git commit -m "chore(deps): update dev dependencies to latest patches"
```

## CI/CD Pipeline

- **`ci.yml`** runs on **all branches**: type check, build (with artifact caching), and the
  full test suite. CI must pass before a release can proceed.
- **`release.yml`** runs only on **alpha / beta / main**: waits for CI, determines the release
  type from the branch, analyzes commits, versions packages with Lerna, updates CHANGELOGs,
  builds, publishes to the GitHub Package Registry, tags each package, and creates GitHub
  releases.

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

## Troubleshooting

- **Release didn't create a version** — no releasable commits (only `chore:`/`docs:`/`test:`
  since the last release), the push went to a feature branch instead of alpha/beta/main, or CI
  failed. Ensure a `feat:`/`fix:` commit, push to a release branch, and check CI.
- **Wrong version number** — a commit didn't follow Conventional Commits, or a breaking change
  wasn't marked with `!` / `BREAKING CHANGE:`. Review the commit messages.
- **Lockfile out of sync in CI** — CI installs with a frozen lockfile. After changing
  `package.json`, run `pnpm install` and commit `package.json` and `pnpm-lock.yaml` together.

## Additional Resources

- [Contributing](./contributing.md) — setup, build, test, daily workflow
- [Conventional Commits](https://conventionalcommits.org/) · [Semantic Versioning](https://semver.org/) · [Lerna](https://lerna.js.org/)
