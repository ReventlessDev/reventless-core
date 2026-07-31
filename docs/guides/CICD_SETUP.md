# CI/CD Pipeline Documentation

This document describes the GitHub Actions CI/CD pipeline for the Reventless monorepo.

## Pipeline Overview

The CI/CD pipeline consists of three main workflows:

1. **Continuous Integration (CI)** - Runs on every push and PR
2. **Release** - Automated package publishing on main branch
3. **Security** - Security scanning and vulnerability detection

## Workflow Details

### 1. Continuous Integration (`.github/workflows/ci.yml`)

Triggered on:
- Push to `main` branch
- Pull requests to `main` branch
- Manual dispatch

#### Jobs:

##### Lint & Format Check
- ESLint code linting
- Prettier formatting validation
- Package.json validation
- Conventional commit validation (for PRs)

##### Type Check & Build
- ReScript compilation
- TypeScript type checking
- Build artifact validation
- Multi-Node.js version testing (20.x, 22.17.1)

##### Test Suite
- Unit tests per package
- Integration tests
- Code coverage reporting
- Coverage upload to Codecov

##### Security Scan
- npm audit for vulnerabilities
- Snyk security scanning
- Dependency vulnerability checks

##### Dependency Analysis
- Circular dependency detection
- Unused dependency identification
- Dependency update suggestions

##### Build Matrix
- Cross-platform testing (Ubuntu, macOS, Windows)
- Multiple Node.js versions
- Build artifact validation

##### Monorepo Validation
- Lerna configuration validation
- Package dependency graph validation
- Workspace protocol enforcement

### 2. Release Workflow (`.github/workflows/release.yml`)

Triggered on:
- Push to `main` branch (automatic)
- Manual dispatch with release type selection

#### Release Process:

1. **Commit Analysis**: Analyzes commits since last release using conventional commits
2. **Version Determination**: Determines version bump type (patch/minor/major)
3. **Package Versioning**: Updates package versions using Lerna
4. **Changelog Generation**: Creates/updates CHANGELOG.md files
5. **Build Artifacts**: Clean build of all packages
6. **Tiered Publishing**: Publishes packages in dependency order
7. **Git Tagging**: Creates and pushes version tags
8. **GitHub Releases**: Creates GitHub releases with notes
9. **Documentation Updates**: Updates version references

#### Publishing Tiers:

**Tier 0** (No dependencies):
- `rescript-hash-obj`
- `rescript-node`
- `rescript-pulumi-pulumi`
- `rescript-uuid`

**Tier 1** (Depends on Tier 0):
- `rescript-aws-sdk`
- `rescript-fast-csv`
- `rescript-pulumi-aws`
- `rescript-ssh2`

**Tier 2** (Depends on Tier 0 & 1):
- `reventless` (core framework)
- `reventless-aws`
- `reventless-spec`
- `reventless-ui`
- `reventless-ci`

### 3. Security Workflow (`.github/workflows/security.yml`)

Triggered on:
- Push to `main` branch
- Pull requests to `main` branch
- Daily schedule (2 AM UTC)
- Manual dispatch

#### Security Checks:

##### Dependency Security Scan
- npm audit with moderate+ severity threshold
- Snyk vulnerability scanning
- SARIF upload to GitHub Security tab

##### CodeQL Analysis
- Static analysis for JavaScript/TypeScript
- Security and quality queries
- Automated security issue detection

##### Secret Scanning
- TruffleHog for secret detection
- Historical commit scanning
- Verified secrets only

##### License Compliance
- License compatibility checking
- Allowed licenses: MIT, Apache-2.0, BSD variants, ISC
- License report generation

##### Vulnerability Database
- audit-ci for comprehensive vulnerability checking
- Custom vulnerability allowlist support
- Detailed vulnerability reporting

## Configuration Files

### `.npmrc`
```ini
registry=https://registry.npmjs.org
access=public
audit-level=moderate

# CI publish auth (installs of public packages need no token)
//registry.npmjs.org/:_authToken=${NPM_TOKEN}
```

### `lerna.json`
```json
{
  "version": "independent",
  "npmClient": "npm",
  "packages": ["packages/*"],
  "command": {
    "publish": {
      "registry": "https://registry.npmjs.org",
      "access": "public",
      "conventionalCommits": true
    },
    "version": {
      "conventionalCommits": true,
      "allowBranch": ["main"],
      "createRelease": "github"
    }
  }
}
```

### `.releaserc.json`
Semantic release configuration with:
- Conventional commits analysis
- Automated changelog generation
- GitHub releases creation
- npm package publishing

### `.github/dependabot.yml`
Automated dependency updates for:
- npm packages (weekly)
- GitHub Actions (weekly)
- Docker images (weekly)
- Grouped updates by category

## Environment Variables & Secrets

### Required Secrets:
- `GITHUB_TOKEN` - Automatically provided, needs packages:write
- `NPM_TOKEN` - Optional, for future npm public registry publishing
- `SNYK_TOKEN` - Optional, for Snyk security scanning
- `CODECOV_TOKEN` - Optional, for code coverage reporting
- `SLACK_WEBHOOK` - Optional, for release notifications

### Environment Variables:
- `GITHUB_TOKEN` - Set to `${{ secrets.GITHUB_TOKEN }}` in workflows
- `CI` - Set to `true` for test environments

## Branch Protection Rules

### Main Branch Protection:
- Require pull request reviews (1 reviewer)
- Enable Kilo Code Reviewer for automated code reviews
- Require status checks to pass:
  - `lint-and-format`
  - `type-check-and-build`
  - `test`
  - `security-scan`
  - `validate-monorepo`
- Require branches to be up to date
- Restrict pushes to main branch
- Require signed commits (recommended)

## Conventional Commits

The pipeline uses conventional commits for automated versioning:

### Commit Format:
```
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

### Types:
- `feat` - New feature (minor version)
- `fix` - Bug fix (patch version)
- `perf` - Performance improvement (patch version)
- `BREAKING CHANGE` - Breaking change (major version)
- `docs` - Documentation changes (no version bump)
- `style` - Code style changes (no version bump)
- `refactor` - Code refactoring (patch version)
- `test` - Test changes (no version bump)
- `build` - Build system changes (patch version)
- `ci` - CI configuration changes (no version bump)

### Examples:
```bash
feat(core): add event replay functionality
fix(aws): resolve DynamoDB timeout issue
perf(ui): optimize component rendering
docs: update API documentation
BREAKING CHANGE: redesign event interface
```

## Monitoring & Metrics

### Key Performance Indicators:
- **Build Success Rate**: Target >95%
- **Average Build Time**: Target <10 minutes
- **Test Coverage**: Target >80%
- **Security Vulnerabilities**: Target 0 high/critical
- **Time to Release**: Target <30 minutes

### Monitoring Tools:
- GitHub Actions insights
- Package download analytics
- Security vulnerability alerts
- Dependabot update tracking

## Troubleshooting

### Common Issues:

#### Build Failures
1. Check Node.js version compatibility
2. Verify dependency installation
3. Review build logs for specific errors
4. Check for environment-specific issues

#### Test Failures
1. Run tests locally first
2. Check for missing test dependencies
3. Verify test environment setup
4. Review test isolation issues

#### Publishing Failures
1. Verify GitHub token permissions
2. Check package.json configuration
3. Ensure proper package naming
4. Validate build artifacts

#### Security Scan Issues
1. Review vulnerability details
2. Update vulnerable dependencies
3. Add exceptions for false positives
4. Check license compatibility

### Debug Commands:
```bash
# Local build test
npm run build

# Local test run
npm run test

# Dependency audit
npm audit

# Lerna validation
npx lerna list --all
npx lerna ls --graph

# Package validation
npm pack --dry-run
```

## Performance Optimization

### Build Optimization:
- Dependency caching with `actions/cache`
- Parallel job execution
- Conditional job execution
- Artifact sharing between jobs

### Test Optimization:
- Test parallelization
- Selective test execution
- Coverage optimization
- Test result caching

### Security Optimization:
- Scheduled security scans
- Incremental vulnerability checking
- Security result caching
- False positive filtering

## Maintenance

### Weekly Tasks:
- Review Dependabot PRs
- Check build performance metrics
- Update security allowlists if needed

### Monthly Tasks:
- Security audit review
- Performance optimization review
- Dependency cleanup
- Documentation updates

### Quarterly Tasks:
- Workflow optimization review
- Security posture assessment
- Tool version updates
- Process improvement evaluation

## Support

### Getting Help:
1. Check workflow logs in GitHub Actions tab
2. Review this documentation
3. Search existing GitHub issues
4. Create new issue with logs and details

### Escalation:
- Critical build failures: Immediate attention
- Security vulnerabilities: Within 24 hours
- Performance issues: Within 1 week
- Feature requests: Next sprint planning

---

*This documentation is maintained by the DevOps team. Last updated: 2026-02-04*