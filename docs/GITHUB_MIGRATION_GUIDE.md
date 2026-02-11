# GitHub CI/CD Migration Guide

This guide provides step-by-step instructions for migrating from GitLab to GitHub with the new CI/CD pipeline.

## Overview

The migration involves:
- Moving from GitLab Package Registry to GitHub Packages
- Implementing GitHub Actions for CI/CD
- Setting up automated releases with semantic versioning
- Configuring security scanning and dependency management

## Prerequisites

### Required Permissions
- **Repository Admin**: To configure branch protection rules and secrets
- **Packages Write**: To publish packages to GitHub Packages
- **Actions Write**: To configure GitHub Actions workflows

### Required Secrets
Configure the following secrets in your GitHub repository settings:

| Secret Name | Description | Required |
|-------------|-------------|----------|
| `GITHUB_TOKEN` | Automatically provided by GitHub | ✅ |
| `NPM_TOKEN` | For fallback npm registry access | ⚠️ Optional |
| `SNYK_TOKEN` | For security vulnerability scanning | ⚠️ Optional |
| `CODECOV_TOKEN` | For code coverage reporting | ⚠️ Optional |
| `SLACK_WEBHOOK` | For release notifications | ⚠️ Optional |

## Migration Steps

### Phase 1: Repository Setup

#### 1.1 Enable GitHub Packages
1. Go to repository **Settings** → **General**
2. Scroll to **Features** section
3. Enable **Packages**

#### 1.2 Configure Package Permissions
1. Go to repository **Settings** → **Actions** → **General**
2. Under **Workflow permissions**, select:
   - ✅ **Read and write permissions**
   - ✅ **Allow GitHub Actions to create and approve pull requests**

#### 1.3 Set Up Branch Protection
1. Go to repository **Settings** → **Branches**
2. Add rule for `main` branch:
   ```
   Branch name pattern: main
   ✅ Require a pull request before merging
   ✅ Require approvals (1)
   ✅ Dismiss stale PR approvals when new commits are pushed
   ✅ Require review from code owners
   ✅ Require status checks to pass before merging
   ✅ Require branches to be up to date before merging
   ✅ Require conversation resolution before merging
   ✅ Restrict pushes that create files
   ✅ Do not allow bypassing the above settings
   ```

3. Enable Kilo Code Reviewer:
   - Go to repository **Settings** → **Code security and analysis**
   - Enable **Kilo Code Reviewer** for automated code reviews
   - Configure review settings to complement human reviews

### Phase 2: Package Configuration

#### 2.1 Update Package Registry Configuration
The migration includes updated configuration files:

- **`.npmrc`**: Configured for GitHub Packages registry
- **`lerna.json`**: Updated with GitHub Packages settings
- **`.releaserc.json`**: Semantic release configuration

#### 2.2 Update Package.json Files
For each package in the monorepo, ensure:

```json
{
  "name": "@reventless/package-name",
  "publishConfig": {
    "registry": "https://npm.pkg.github.com"
  },
  "repository": {
    "type": "git",
    "url": "https://github.com/your-org/reventless.git",
    "directory": "packages/package-name"
  }
}
```

### Phase 3: CI/CD Pipeline Setup

#### 3.1 Workflow Files
The following GitHub Actions workflows are included:

| Workflow | File | Purpose |
|----------|------|---------|
| **CI** | `.github/workflows/ci.yml` | Continuous integration |
| **Release** | `.github/workflows/release.yml` | Automated releases |
| **Security** | `.github/workflows/security.yml` | Security scanning |

#### 3.2 Dependabot Configuration
- **`.github/dependabot.yml`**: Automated dependency updates

### Phase 4: Testing and Validation

#### 4.1 Test CI Pipeline
1. Create a test branch: `git checkout -b test/ci-pipeline`
2. Make a small change and push
3. Create a pull request
4. Verify all CI checks pass

#### 4.2 Test Release Process
1. Merge a commit with conventional commit format:
   ```bash
   git commit -m "feat: add new feature for testing"
   ```
2. Push to main branch
3. Verify release workflow triggers
4. Check packages are published to GitHub Packages

#### 4.3 Validate Package Installation
Test installing packages from GitHub Packages:

```bash
# Configure npm for GitHub Packages
echo "@reventless:registry=https://npm.pkg.github.com" >> ~/.npmrc
echo "//npm.pkg.github.com/:_authToken=YOUR_GITHUB_TOKEN" >> ~/.npmrc

# Test installation
npm install @reventless/reventless
```

## Package Publishing Order

The release workflow publishes packages in dependency order:

### Tier 0 (No Dependencies)
- `@reventless/rescript-hash-obj`
- `@reventless/rescript-node-streams`
- `@reventless/rescript-pulumi-pulumi`
- `@reventless/rescript-uuid`

### Tier 1 (Depends on Tier 0)
- `@reventless/rescript-aws-sdk`
- `@reventless/rescript-fast-csv`
- `@reventless/rescript-pulumi-aws`
- `@reventless/rescript-ssh2`

### Tier 2 (Depends on Tier 0 & 1)
- `@reventless/reventless`
- `@reventless/reventless-aws`
- `@reventless/reventless-spec`
- `@reventless/reventless-ui`
- `@reventless/reventless-ci`

## Conventional Commits

The release process uses conventional commits for automatic versioning:

### Commit Types
| Type | Description | Version Bump |
|------|-------------|--------------|
| `feat` | New feature | Minor |
| `fix` | Bug fix | Patch |
| `perf` | Performance improvement | Patch |
| `BREAKING CHANGE` | Breaking change | Major |
| `docs` | Documentation only | None |
| `style` | Code style changes | None |
| `refactor` | Code refactoring | Patch |
| `test` | Test changes | None |
| `build` | Build system changes | Patch |
| `ci` | CI configuration changes | None |

### Examples
```bash
# Feature (minor version bump)
git commit -m "feat(core): add new event processing capability"

# Bug fix (patch version bump)
git commit -m "fix(aws): resolve DynamoDB connection timeout"

# Breaking change (major version bump)
git commit -m "feat(api): redesign event interface

BREAKING CHANGE: Event interface now requires explicit type parameter"

# Documentation (no version bump)
git commit -m "docs: update installation instructions"
```

## Monitoring and Maintenance

### Build Status
Monitor build status at:
- **Actions tab**: `https://github.com/your-org/reventless/actions`
- **Packages tab**: `https://github.com/your-org/reventless/packages`

### Key Metrics to Monitor
- ✅ Build success rate (target: >95%)
- ⏱️ Average build time (target: <10 minutes)
- 📊 Test coverage (target: >80%)
- 🔒 Security vulnerabilities (target: 0 high/critical)

### Regular Maintenance Tasks
- **Weekly**: Review Dependabot PRs
- **Monthly**: Security audit review
- **Quarterly**: Performance optimization review

## Troubleshooting

### Common Issues

#### 1. Package Publishing Fails
**Symptoms**: Release workflow fails at publishing step
**Solutions**:
- Verify `GITHUB_TOKEN` has packages:write permission
- Check package.json `publishConfig` is correct
- Ensure package name follows `@reventless/` scope

#### 2. CI Tests Fail
**Symptoms**: Tests pass locally but fail in CI
**Solutions**:
- Check Node.js version matches (22.17.1)
- Verify all dependencies are in package.json
- Check for environment-specific issues

#### 3. Dependency Installation Issues
**Symptoms**: `npm ci` fails in workflows
**Solutions**:
- Verify `.npmrc` configuration
- Check package-lock.json is committed
- Ensure all internal dependencies use workspace protocol

#### 4. Release Not Triggered
**Symptoms**: Commits to main don't trigger releases
**Solutions**:
- Verify commit follows conventional commit format
- Check if changes are in ignored paths
- Ensure workflow has proper permissions

### Getting Help

1. **Check workflow logs**: Go to Actions tab and review failed workflow logs
2. **Review documentation**: Check this guide and GitHub Actions documentation
3. **Create issue**: Open a GitHub issue with workflow logs and error details

## Rollback Plan

If issues occur during migration:

### Emergency Rollback
1. **Disable GitHub Actions**:
   ```bash
   # Disable workflows temporarily
   git mv .github/workflows .github/workflows.disabled
   git commit -m "chore: disable GitHub Actions temporarily"
   git push origin main
   ```

2. **Revert package configurations**:
   ```bash
   # Restore GitLab registry settings
   git checkout HEAD~1 -- .npmrc lerna.json
   git commit -m "chore: revert to GitLab registry"
   git push origin main
   ```

3. **Manual package publishing**:
   ```bash
   # Publish to GitLab registry manually
   npm config set @reventless:registry https://gitlab.com/api/v4/projects/24127696/packages/npm/
   npx lerna publish --registry https://gitlab.com/api/v4/projects/24127696/packages/npm/
   ```

### Recovery Steps
1. Identify and fix the root cause
2. Test fixes in a separate branch
3. Re-enable GitHub Actions gradually
4. Monitor closely for 24-48 hours

## Success Criteria

### Technical Validation
- [ ] All packages build successfully
<!-- - [ ] Test coverage >80% -->
- [ ] Build time <10 minutes
- [ ] Zero high/critical security vulnerabilities
- [ ] All packages published to GitHub Packages

### Process Validation
- [ ] Automated releases working correctly
- [ ] Conventional commits triggering appropriate version bumps
- [ ] Branch protection rules enforced
- [ ] Dependabot PRs being created
- [ ] Security scans running daily

### Team Validation
- [ ] Development team trained on new workflows
- [ ] Documentation updated and accessible
- [ ] Rollback plan tested and validated
- [ ] Monitoring and alerting configured

## Next Steps

After successful migration:

1. **Monitor Performance**: Track build times and success rates
2. **Optimize Workflows**: Fine-tune based on usage patterns
3. **Team Training**: Conduct workshops on new processes
4. **Documentation Updates**: Keep guides current with changes
5. **Security Reviews**: Regular security posture assessments

---

*For questions or issues with this migration, please create a GitHub issue or contact the DevOps team.*