# Registry and Token Configuration

Reventless packages are currently published to **GitHub Package Registry**. This guide covers how to authenticate for installing and publishing packages.

## Installing Packages

All `@reventlessdev/*` packages are on GitHub Package Registry and require a GitHub personal access token with `read:packages` scope.

### 1. Create a GitHub Token

1. Go to [GitHub Settings → Developer Settings → Personal Access Tokens → Tokens (classic)](https://github.com/settings/tokens)
2. Generate a new token with the `read:packages` scope
3. For publishing, also add `write:packages`

### 2. Set the Environment Variable

The token must be available as `GITHUB_TOKEN`:

```bash
# Local development — add to your shell profile (~/.zshrc, ~/.bashrc)
export GITHUB_TOKEN="ghp_..."
```

### 3. CI/CD Configuration

In GitHub Actions, the built-in `GITHUB_TOKEN` secret works automatically:

```yaml
steps:
  - name: Install dependencies
    run: npm ci
    env:
      GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

## `.npmrc` Configuration

The root `.npmrc` configures GitHub Package Registry for `@reventlessdev` scoped packages:

```ini
@reventlessdev:registry=https://npm.pkg.github.com
registry=https://registry.npmjs.org

# Authentication token will be provided via GITHUB_TOKEN environment variable
//npm.pkg.github.com/:_authToken=${GITHUB_TOKEN}
```

## Token Summary

| Variable | Where | Purpose |
|---|---|---|
| `GITHUB_TOKEN` | Secret / env var / CI | GitHub Package Registry token for installing and publishing |

## Future: npm Public Registry

When core packages move to npm public registry, a second token (`NPM_TOKEN`) will be introduced for publishing to npmjs.com. Installing public packages from npm will not require a token.
