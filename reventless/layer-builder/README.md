# Reventless Layer Builder

Builds optimized AWS Lambda layers for `@reventlessdev/reventless-aws`.

## Architecture

```
reventless/layer-builder/
├── src/
│   ├── Main.res                           # Entry point: the Reventless config
│   ├── DependencyBundler.res              # Build orchestration
│   ├── DependencyBundler_Config.res       # Config type
│   ├── DependencyBundler_Filter.res       # Inclusion/exclusion logic
│   ├── DependencyBundler_PostProcess.res  # Per-package file cleanup
│   ├── DependencyBundler_Stats.res
│   ├── Packaging.res, Packaging_AwsLambdaLayer.res
│   ├── RegistryRetry.res                  # Retry wrapper for npmjs registry reads
│   └── bindings/                          # Arborist, Pacote, Treeverse, ZipAFolder, …
├── builder/
│   ├── layer/                # Build output (gitignored)
│   │   └── nodejs/
│   │       └── node_modules/
│   └── reventless-layer.zip  # Final layer artifact (gitignored)
├── tests/
└── iam-policy.json           # IAM policy for CI publishing
```

Two-part system:
- **Generic builder** (`DependencyBundler*.res`): builds a Lambda layer from any npm package using Arborist + Pacote + Treeverse
- **Reventless config** (`Main.res`): Reventless-specific exclusions, inclusions, and post-processing

## Building Locally

From this directory, after `pnpm run setup` at the repo root:

```bash
REVENTLESS_AWS_VERSION=3.0.0-alpha.346 pnpm run build
```

No token is needed — `@reventlessdev/*` packages are public on npmjs. Without
`REVENTLESS_AWS_VERSION` the build takes the `latest` dist-tag. The result is
`builder/reventless-layer.zip`.

## Build Process

1. **Clean** — Delete previous layer directory
2. **Extract** — Download `@reventlessdev/reventless-aws@<version>` from npmjs
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

## Configuration

`DependencyBundler_Config.t`, of which `Main.res` holds the one instance:

```rescript
type t = {
  sourcePackageName: string,       // Package to build the layer from
  sourcePackageVersion: string,    // From REVENTLESS_AWS_VERSION (default: "latest")
  pathToLayerData: string,         // Root directory for layer content
  pathToSavedDependencies: string, // Where to extract node_modules
  excludeScopes: array<string>,    // npm scopes to exclude (without @)
  excludeModules: array<string>,   // Specific packages to exclude
  includeModules?: array<string>,
  includeScopes?: array<string>,
  registryOpts: Dict.t<string>,    // @reventlessdev scope → registry.npmjs.org, no auth
  postProcess: postProcessMap,     // Per-package post-processing
  rootPostProcess?: DependencyBundler_PostProcess.postProcessFn,
}
```

## CI/CD

### GitHub Actions Workflow

`.github/workflows/build-lambda-layer.yml` runs:
- when the release workflow dispatches it after releasing `@reventlessdev/reventless-aws`, with the released version
- on a push to `main`/`beta`/`alpha` that changes `reventless/layer-builder/**`
- manually, via `workflow_dispatch` with a version input

The workflow builds the layer, publishes it to AWS Lambda in the CI account, stores its ARN in SSM at `/reventless/layer-arn/{stack}`, uploads the zip as a GitHub release asset, and appends the layer ARN to the release notes.

### IAM Setup

The CI user `reventless-ci-layer-publisher` has minimal permissions. `iam-policy.json`
is the tracked source-of-truth document; it is applied as the customer-managed
policy `reventless-ci-lambda-layer-publish` attached to that user (update the live
policy by creating a new version from this file). It grants:
- `lambda:PublishLayerVersion`
- `lambda:GetLayerVersion`
- Scoped to `arn:aws:lambda:*:*:layer:reventless-aws*`
- `ssm:PutParameter` on `arn:aws:ssm:*:*:parameter/reventless/layer-arn/*` — the
  build job stores the published ARN there for the deploy workflow to read.

GitHub secrets: `AWS_LAYER_ACCESS_KEY_ID`, `AWS_LAYER_SECRET_ACCESS_KEY`

> The **deploy** CI users (core and business `AWS_ACCESS_KEY_ID`) need the
> matching `ssm:GetParameter` on the same path to read the ARN at deploy time.
> Those users' policies are managed in AWS, not tracked here.

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

A deploy takes the layer ARN from `REVENTLESS_LAYER_ARN`, or else from the SSM
parameter `/reventless/layer-arn/<stack>` in the deploy region. The CI account's
layer cannot be used from another account: publish the zip there yourself and
write the parameter.

```bash
LAYER_ARN=$(aws lambda publish-layer-version \
  --layer-name reventless-aws \
  --zip-file fileb://builder/reventless-layer.zip \
  --compatible-runtimes nodejs20.x nodejs22.x \
  --query LayerVersionArn --output text)

aws ssm put-parameter --name "/reventless/layer-arn/<stack>" \
  --type String --overwrite --value "$LAYER_ARN"
```

The zip is also attached to each `@reventlessdev/reventless-aws` GitHub release, so building is optional.

## Troubleshooting

**Registry error during extract**: `@reventlessdev/*` is read anonymously from npmjs — check that the requested `REVENTLESS_AWS_VERSION` is published.

**Layer exceeds 50 MB**: Check for new large dependencies. Add to `excludeScopes`, `excludeModules`, or add a postprocess handler.

**Stale packages in layer**: The build now cleans `layer/` before each run. If you see unexpected packages, verify `excludeScopes` covers them.
