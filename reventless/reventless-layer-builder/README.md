# Reventless Layer Builder

Builds optimized AWS Lambda layers for `@reventlessdev/reventless-aws`.

## Architecture

```
reventless-layer-builder/
├── src/
│   └── index.js              # Generic layer builder library
├── builder/
│   ├── index.js              # Entry point (Reventless config)
│   ├── postprocess.js        # Package-specific cleanup functions
│   ├── layer/                # Build output (gitignored)
│   │   └── nodejs/
│   │       └── node_modules/
│   └── reventless-layer.zip  # Final layer artifact (gitignored)
└── iam-policy.json           # IAM policy for CI publishing
```

Two-part system:
- **Generic Library** (`src/index.js`): Builds Lambda layers from any npm package using Arborist + Pacote + Treeverse
- **Reventless Config** (`builder/`): Reventless-specific configuration, exclusions, and post-processing

## Building Locally

```bash
# Set your GitHub Package Registry token (needs read:packages scope)
export GITHUB_TOKEN="ghp_..."

# Build the layer
REVENTLESS_AWS_VERSION=3.0.0-alpha.9 npm run build
```

Enable debug logging with `DEBUG='lib,lib:*'`.

## Build Process

1. **Clean** — Delete previous layer directory
2. **Extract** — Download `@reventlessdev/reventless-aws@<version>` from GitHub Package Registry
3. **Resolve** — Build dependency tree with Arborist (deduplication enabled)
4. **Filter** — Exclude dev/optional/peer deps, excluded scopes and modules
5. **Extract Dependencies** — Download each necessary dependency
6. **Post-process** — Remove unnecessary files (`.res` sources, test dirs, etc.)
7. **Zip** — Create `reventless-layer.zip` with `nodejs/node_modules/` structure

### Dependency Filtering

Excluded scopes (`@<scope>/*`): `pulumi`, `types`, `opentelemetry`, `aws-sdk`, `smithy`, `sigstore`

Excluded modules: `aws-sdk`, `sury-ppx`

AWS SDK packages are excluded because Lambda provides them at runtime. `sury-ppx` is a build-time PPX binary (93 MB) not needed at runtime.

### Post-Processing

| Entry | Action |
|-------|--------|
| `">rescript"` | Delete `.res` and `.resi` source files from any package depending on `rescript` |
| `"@reventlessdev/reventless-core"` | Delete `coverage/`, `scripts/`, `test-helper/`, `tests/` |
| `"@reventlessdev/rescript-effect"` | Delete `tests/` |
| `"effect"` | Delete `src/` (7.5 MB of TypeScript source) |

Post-process keys prefixed with `>` match any package that has the named dependency.

## Library API

### `build(options)`

```javascript
{
  sourcePackageName: string,       // Package to build layer from
  sourcePackageVersion: string,    // Version (default: 'latest')
  pathToLayerData: string,         // Root directory for layer content
  pathToSavedDependencies: string, // Where to extract node_modules
  excludeScopes: string[],        // npm scopes to exclude (without @)
  excludeModules: string[],       // Specific packages to exclude
  registryOpts: object,           // npm registry authentication config
  postProcess: {                  // Post-processing functions
    "package-name": (node, cwd) => Promise<void>,
    ">dependency": (node, cwd) => Promise<void>
  }
}
```

## CI/CD

### GitHub Actions Workflow

`.github/workflows/build-lambda-layer.yml` triggers on:
- Tag push: `@reventlessdev/reventless-aws@*`
- Manual: `workflow_dispatch` with version input

The workflow builds the layer, publishes to AWS Lambda, uploads the zip as a GitHub release asset, and appends the layer ARN to the release notes.

### IAM Setup

The CI user `reventless-ci-layer-publisher` has minimal permissions defined in `iam-policy.json`:
- `lambda:PublishLayerVersion`
- `lambda:GetLayerVersion`
- Scoped to `arn:aws:lambda:*:*:layer:reventless-aws*`

GitHub secrets: `AWS_LAYER_ACCESS_KEY_ID`, `AWS_LAYER_SECRET_ACCESS_KEY`

## Lambda Layer Structure

```
reventless-layer.zip
└── nodejs/
    └── node_modules/
        ├── @reventlessdev/
        │   ├── reventless-aws/
        │   ├── reventless-core/
        │   └── ...
        ├── sury/
        ├── uuid/
        ├── effect/
        └── ...
```

When attached to a Lambda function, the layer is extracted to `/opt/`, making packages available at `/opt/nodejs/node_modules/`.

## Using the Layer

Reference the layer ARN from the GitHub release notes in your Pulumi stack config:

```yaml
# Pulumi.<stack>.yaml
config:
  reventless:layerArn: "arn:aws:lambda:eu-west-1:123456789:layer:reventless-aws:1"
```

## Troubleshooting

**Authentication error**: Ensure `GITHUB_TOKEN` is a classic personal access token with `read:packages` scope.

**Layer exceeds 50 MB**: Check for new large dependencies. Add to `excludeScopes`, `excludeModules`, or add a postprocess handler.

**Stale packages in layer**: The build now cleans `layer/` before each run. If you see unexpected packages, verify `excludeScopes` covers them.
