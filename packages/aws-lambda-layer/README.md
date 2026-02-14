# AWS Lambda Layer Builder

This package provides tooling to build optimized AWS Lambda layers for the Reventless framework. It consists of two main components:

1. **[Library (`src/`)](#library-srcindexjs)**: A generic, reusable builder for creating Lambda layers from npm packages
2. **[Builder (`builder/`)](#builder-configuration)**: Reventless-specific configuration and build scripts

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Library (`src/index.js`)](#library-srcindexjs)
- [Builder Configuration](#builder-configuration)
- [Build Process Details](#build-process-details)
- [Layer Structure](#layer-structure)
- [GitHub Migration](#github-migration)
- [Automated Layer Creation](#automated-layer-creation)
- [Usage](#usage)
- [Publishing to AWS](#publishing-to-aws)

---

## Architecture Overview

### Two-Part System

The package is designed with separation of concerns:

- **Generic Library** (`src/index.js`): Provider-agnostic code that can build layers for any npm package
- **Reventless Builder** (`builder/`): Configuration and scripts specific to `@reventless/reventless-aws`

This separation allows the library to be reused for other packages while the builder handles Reventless-specific concerns like:
- ReScript compilation artifacts
- Precompiled modules
- Package-specific post-processing
- Dependency filtering

### Key Components

```
aws-lambda-layer/
├── src/
│   └── index.js              # Generic layer builder library
├── builder/
│   ├── index.js              # Entry point (Reventless config)
│   ├── builder.js            # Main build orchestration (DEPRECATED - uses older lib version)
│   ├── postprocess.js        # Package-specific cleanup functions
│   ├── precompiled/          # Pre-built ReScript modules
│   │   ├── @rescript/
│   │   ├── @rescript-labs/
│   │   ├── bs-moment@0.8.0/
│   │   └── decco@1.6.0/
│   ├── layer/
│   │   └── nodejs/
│   │       └── node_modules/ # Extracted dependencies
│   └── reventless-layer.zip  # Final layer artifact (~31MB)
```

---

## Library (`src/index.js`)

### Overview

The library uses npm's native tooling to build Lambda-compatible dependency trees:

- **[@npmcli/arborist](https://www.npmjs.com/package/@npmcli/arborist)**: npm's internal dependency tree resolver
- **[pacote](https://www.npmjs.com/package/pacote)**: npm's package downloader and extractor
- **[treeverse](https://www.npmjs.com/package/treeverse)**: Tree traversal utilities for npm trees

### API

#### `build(options)`

Main entry point for building Lambda layers.

**Parameters:**

```javascript
{
  sourcePackageName: string,         // Package to create layer from
  sourcePackageVersion: string,      // Version to use (default: 'latest')
  pathToLayerData: string,           // Root directory for layer content
  pathToSavedDependencies: string,   // Where to extract node_modules
  excludeScopes: string[],           // npm scopes to exclude (e.g., ['pulumi', 'types'])
  excludeModules: string[],          // Specific packages to exclude
  postProcess: {                     // Post-processing functions
    "package-name": (node, cwd) => Promise<void>,
    ">dependency-name": (node, cwd) => Promise<void>  // Process dependents
  }
}
```

**Post-Processing Keys:**
- `"package-name"`: Process the specific package
- `">dependency-name"`: Process any package that depends on `dependency-name`

### Key Features

#### 1. Intelligent Dependency Filtering

The library automatically excludes:
- Dev dependencies (`dev`, `devOptional`)
- Optional dependencies
- Peer dependencies
- Packages in excluded scopes
- Specific excluded modules
- Packages only required by excluded dependencies

#### 2. Tree Deduplication

Uses Arborist's `preferDedupe: true` to minimize duplicate dependencies, reducing layer size.

#### 3. Post-Processing Hooks

Allows custom cleanup for specific packages:
```javascript
postProcess: {
  "@rescript-labs/decco": async (node, cwd) => {
    // Remove PPX binaries (not needed at runtime)
    await rimraf('ppx*', {glob: {cwd}});
  },
  ">rescript": async (node, cwd) => {
    // Remove .res source files from ANY package that depends on rescript
    await rimraf('**/*.res', {glob: {cwd}});
    await rimraf('**/*.resi', {glob: {cwd}});
  }
}
```

---

## Builder Configuration

### Current Implementation (`builder/builder.js`)

**⚠️ Note**: The current `builder/builder.js` is using a **standalone, older version** of the library code instead of importing from `src/index.js`. This provides more control but creates maintenance overhead.

#### Configuration

```javascript
const options = {
  sourcePackageName: '@reventless/reventless-aws',
  sourcePackageVersion: '2.0.3-policies.73',

  // Paths
  pathToLayerData: './layer/',
  pathToSavedDependencies: './layer/nodejs/node_modules',
  pathToPrecompiled: './precompiled/',

  // Precompiled modules (override downloaded versions)
  precompiledModules: {
    '@rescript-labs/decco': '@rescript-labs/decco@2.0.4',
    '@rescript/core': '@rescript/core'
  },

  // Additional modules required by applications
  includePrecompiledModules: {
    '@reventless/rescript-moment': 'bs-moment@0.8.0'
  },

  // Exclusions
  excludeScopes: ['@pulumi', '@types', '@opentelemetry', '@aws-sdk',
                  '@protobufjs', '@npmcli', '@sigstore'],
  excludeModules: ['rescript', 'treeverse', 'pacote', 'aws-sdk', ...],
  excludedFileFormats: ['.res', '.resi', '.ts', '.cts'],

  // Registry authentication (GitHub)
  gitlabOpts: {
    "@reventless:registry": "https://github.com/api/v4/packages/npm/",
    "//github.com/api/v4/projects/.../packages/npm/:_authToken": process.env.NPM_GITLAB_TOKEN,
    ...
  }
};
```

### Precompiled Modules

Some ReScript packages don't ship compiled JavaScript artifacts. These must be:
1. Compiled locally
2. Copied to `builder/precompiled/`
3. Referenced in the build configuration

**Current Precompiled Packages:**
- `@rescript/core@1.6.1`
- `@rescript-labs/decco@2.0.4`
- `bs-moment@0.8.0`
- `decco@1.6.0`

---

## Build Process Details

### Step-by-Step Execution

#### Phase 1: Cleanup
```javascript
1. Delete contents of layer/nodejs/node_modules/
2. Preserve layer/nodejs/ directory structure
```

#### Phase 2: Extract Source Package
```javascript
1. Download @reventless/reventless-aws@<version> from registry
2. Extract to layer/nodejs/node_modules/@reventless/reventless-aws/
3. Parse package.json dependencies
```

#### Phase 3: Build Dependency Tree
```javascript
1. Use Arborist to resolve full dependency graph
2. Apply deduplication (hoist shared dependencies)
3. Calculate tree statistics:
   - Total nodes
   - Direct children
   - Nested dependencies
   - Max depth
```

#### Phase 4: Filter Dependencies
```javascript
For each node in tree:
  1. Check if dev/optional/peer dependency → EXCLUDE
  2. Check if in excluded scope (@pulumi, @types, etc.) → EXCLUDE
  3. Check if in excluded modules list → EXCLUDE
  4. Check if only required by excluded packages → EXCLUDE
  5. If production dependency → INCLUDE
```

#### Phase 5: Extract Dependencies
```javascript
For each included dependency:
  1. Check if precompiled version exists
     → YES: Copy from precompiled/ directory
     → NO: Download from registry with pacote

  2. Extract to layer/nodejs/node_modules/<package-name>/

  3. Apply post-processing:
     - Package-specific cleanup
     - Dependent package cleanup (>dependency-name rules)

  4. Remove excluded file formats (.res, .resi, .ts, .cts)

  5. Increment extraction counter
```

#### Phase 6: Add Required Modules
```javascript
For each includePrecompiledModules entry:
  1. Copy from precompiled/ to node_modules/
  2. These are needed by applications but not in reventless-aws deps
```

#### Phase 7: Create Zip Archive
```javascript
1. Zip entire layer/ directory
2. Output: builder/reventless-layer.zip (~31MB)
3. Maintains nodejs/node_modules/ structure for Lambda
```

### Dependency Filtering Logic

The builder uses sophisticated filtering to minimize layer size:

```javascript
// Example: Check if a package is truly necessary
function predIsNecessary(excludedScopes, excludedModules, node) {
  // 1. Direct exclusions
  if (node.dev || node.optional || node.devOptional || node.peer)
    return false;

  if (isNodeScopeExcluded(excludedScopes, node))
    return false;

  if (isNodeExcluded(excludedModules, node))
    return false;

  // 2. Transitive exclusions
  // Trace edges back to root - if all paths go through excluded packages,
  // this package is unnecessary
  const isReachableFromIncludedPackage = depth({
    tree: node,
    visit: node => isExcluded(node),
    getChildren: (node, isExcluded) => {
      if (!isExcluded) {
        return Array.from(node.edgesIn.values())
          .filter(e => e.prod)
          .map(e => e.from);
      }
      return [];
    }
  });

  return isReachableFromIncludedPackage;
}
```

### Post-Processing Examples

```javascript
// Remove PPX binaries from decco (native executables not needed at runtime)
export async function decco(node, cwd, dependenciesPath) {
  return Promise.all([
    copyPrecompiled('@rescript-labs/decco@2.0.4', node.name, dependenciesPath),
    rimraf('ppx*', {glob: {cwd}})
  ]);
}

// Remove ReScript source files from all ReScript packages
export async function rescriptDependent(node, cwd) {
  return Promise.all([
    rimraf('**/*.res', {glob: {cwd}}),
    rimraf('**/*.resi', {glob: {cwd}})
  ]);
}

// Remove test directories from reventless package
export async function reventless(node, cwd) {
  return rimraf([
    resolvePath(cwd, 'coverage'),
    resolvePath(cwd, 'scripts'),
    resolvePath(cwd, 'test-helper'),
    resolvePath(cwd, 'tests')
  ]);
}

// Remove unnecessary moment.js artifacts
export async function moment(node, cwd) {
  return rimraf([
    resolvePath(cwd, 'min'),
    resolvePath(cwd, 'src'),
    resolvePath(cwd, 'dist'),
  ]);
}
```

---

## Layer Structure

### AWS Lambda Layer Format

Lambda layers must follow this structure:

```
reventless-layer.zip
└── nodejs/
    └── node_modules/
        ├── @reventless/
        │   └── reventless-aws/
        ├── moment/
        ├── uuid/
        └── ... (all runtime dependencies)
```

When attached to a Lambda function, the layer is extracted to `/opt/`, making packages available at `/opt/nodejs/node_modules/`, which is automatically added to Node.js's module resolution path.

### Current Layer Statistics

- **Compressed Size**: ~31 MB
- **Packages Included**: ~170 packages (after filtering)
- **Primary Package**: `@reventless/reventless-aws@2.0.3-policies.73`
- **Max Dependency Depth**: Varies by build (typically 3-5 levels after deduplication)

---

## GitHub Migration

### Current State (GitHub)

The builder currently authenticates with GitHub Package Registry:

```javascript
gitlabOpts: {
  "@reventless:registry": "https://github.com/api/v4/packages/npm/",
  "//github.com/api/v4/projects/40879371/packages/npm/:_authToken": process.env.NPM_GITLAB_TOKEN,
  "//github.com/api/v4/projects/43406890/packages/npm/:_authToken": process.env.NPM_GITLAB_TOKEN,
  "//github.com/api/v4/projects/24127696/packages/npm/:_authToken": process.env.NPM_GITLAB_TOKEN,
  "//github.com/api/v4/packages/npm/:_authToken": process.env.NPM_GITLAB_TOKEN
}
```

### Required Changes for GitHub

#### 1. Update Registry Configuration

Replace `gitlabOpts` with `githubOpts`:

```javascript
githubOpts: {
  "@reventless:registry": "https://npm.pkg.github.com",
  "//npm.pkg.github.com/:_authToken": process.env.GITHUB_TOKEN
}
```

**Key Differences:**
- GitHub uses a **single, unified registry** for all packages in an organization
- No per-project authentication URLs
- Simpler authentication with just `GITHUB_TOKEN`
- Registry URL: `https://npm.pkg.github.com` (not GitHub's `/api/v4/` path)

#### 2. Update Environment Variables

**Before (GitHub):**
```bash
export NPM_GITLAB_TOKEN="glpat-xxxxxxxxxxxxxxxxxxxxx"
```

**After (GitHub):**
```bash
export GITHUB_TOKEN="ghp_xxxxxxxxxxxxxxxxxxxxx"
```

**For GitHub Actions:**
```yaml
- name: Build Lambda Layer
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
  run: npm run build
```

#### 3. Update Package Scope

Ensure all Reventless packages use the correct scope:

**Current (GitHub):**
```json
{
  "name": "@reventless/reventless-aws",
  "publishConfig": {
    "registry": "https://github.com/api/v4/packages/npm/"
  }
}
```

**GitHub:**
```json
{
  "name": "@reventlessdev/reventless-aws",
  "publishConfig": {
    "registry": "https://npm.pkg.github.com"
  }
}
```

**⚠️ Note**: Check whether the scope should be `@reventless` or `@reventlessdev` for the GitHub organization.

#### 4. Update Builder Configuration

**In `builder/builder.js`:**

```diff
 const options = {
   sourcePackageName: '@reventlessdev/reventless-aws',  // Update scope if needed
   sourcePackageVersion: '2.0.3-policies.73',
   pathToLayerData,
   pathToSavedDependencies,
   pathToPrecompiled,
   precompiledModules: { ... },
   includePrecompiledModules: { ... },
   excludeScopes: ['@pulumi', '@types', '@opentelemetry', '@aws-sdk',
                   '@protobufjs', '@npmcli', '@sigstore'],
   excludeModules: ['rescript', 'treeverse', 'pacote', ...npmPackages],
   excludedFileFormats: ['.res', '.resi', '.ts', '.cts'],
-  gitlabOpts: {
-    "@reventless:registry": "https://github.com/api/v4/packages/npm/",
-    "//github.com/api/v4/projects/40879371/packages/npm/:_authToken": process.env.NPM_GITLAB_TOKEN,
-    "//github.com/api/v4/projects/43406890/packages/npm/:_authToken": process.env.NPM_GITLAB_TOKEN,
-    "//github.com/api/v4/projects/24127696/packages/npm/:_authToken": process.env.NPM_GITLAB_TOKEN,
-    "//github.com/api/v4/packages/npm/:_authToken": process.env.NPM_GITLAB_TOKEN
-  }
+  githubOpts: {
+    "@reventlessdev:registry": "https://npm.pkg.github.com",
+    "//npm.pkg.github.com/:_authToken": process.env.GITHUB_TOKEN
+  }
 };
```

**In `src/index.js` (if migrating from standalone builder.js):**

Similar changes to registry configuration.

#### 5. Update `.npmrc` Files (if present)

**Before:**
```
@reventless:registry=https://github.com/api/v4/packages/npm/
//github.com/api/v4/packages/npm/:_authToken=${NPM_GITLAB_TOKEN}
```

**After:**
```
@reventlessdev:registry=https://npm.pkg.github.com
//npm.pkg.github.com/:_authToken=${GITHUB_TOKEN}
```

#### 6. Update Documentation References

- [ ] Update `package.json` `bugs.url` field
- [ ] Update references to GitHub in comments
- [ ] Update README examples

---

## Automated Layer Creation

### Strategy Overview

Automatically build and publish new Lambda layers when `@reventless/reventless-aws` is released.

### Implementation Options

#### Option 1: GitHub Actions Workflow (Recommended)

**Pros:**
- Native integration with existing release process
- Uses existing GitHub authentication
- Triggered automatically by releases
- Can publish directly to AWS

**Workflow Implementation:**

Create `.github/workflows/build-lambda-layer.yml`:

```yaml
name: Build Lambda Layer

on:
  # Trigger when reventless-aws is released
  push:
    tags:
      - '@reventlessdev/reventless-aws@*'

  # Allow manual triggering
  workflow_dispatch:
    inputs:
      version:
        description: 'reventless-aws version to build layer for'
        required: true
        default: 'latest'

concurrency:
  group: lambda-layer-${{ github.ref }}
  cancel-in-progress: false

jobs:
  build-layer:
    name: Build and Publish Lambda Layer
    runs-on: ubuntu-latest
    permissions:
      contents: write
      packages: read

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: "22.17.1"
          cache: "npm"
          registry-url: "https://npm.pkg.github.com"

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: eu-west-1  # Configure your region

      - name: Install dependencies
        working-directory: packages/aws-lambda-layer
        run: npm ci
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

      - name: Extract version from tag
        id: version
        run: |
          if [ "${{ github.event_name }}" = "workflow_dispatch" ]; then
            VERSION="${{ inputs.version }}"
          else
            # Extract version from tag: @reventlessdev/reventless-aws@2.3.3 -> 2.3.3
            VERSION="${GITHUB_REF#refs/tags/@reventlessdev/reventless-aws@}"
          fi
          echo "version=$VERSION" >> $GITHUB_OUTPUT
          echo "Building layer for version: $VERSION"

      - name: Update builder configuration
        working-directory: packages/aws-lambda-layer
        run: |
          # Update version in builder/index.js or builder/builder.js
          VERSION="${{ steps.version.outputs.version }}"
          sed -i "s/sourcePackageVersion: '.*'/sourcePackageVersion: '$VERSION'/" builder/builder.js

          # Verify change
          grep "sourcePackageVersion" builder/builder.js

      - name: Build Lambda layer
        working-directory: packages/aws-lambda-layer
        run: npm run build
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

      - name: Verify layer artifact
        working-directory: packages/aws-lambda-layer
        run: |
          if [ ! -f builder/reventless-layer.zip ]; then
            echo "❌ Layer artifact not found"
            exit 1
          fi

          SIZE=$(du -h builder/reventless-layer.zip | cut -f1)
          echo "✅ Layer artifact created: $SIZE"
          echo "layer_size=$SIZE" >> $GITHUB_OUTPUT
        id: verify

      - name: Publish to AWS Lambda
        working-directory: packages/aws-lambda-layer
        run: |
          VERSION="${{ steps.version.outputs.version }}"
          LAYER_NAME="reventless-aws"
          DESCRIPTION="reventless-aws@$VERSION"

          # Publish layer version
          LAYER_VERSION=$(aws lambda publish-layer-version \
            --layer-name "$LAYER_NAME" \
            --description "$DESCRIPTION" \
            --zip-file fileb://builder/reventless-layer.zip \
            --compatible-runtimes nodejs18.x nodejs20.x \
            --compatible-architectures x86_64 arm64 \
            --region eu-west-1 \
            --query 'Version' \
            --output text)

          echo "✅ Published layer version: $LAYER_VERSION"
          echo "layer_version=$LAYER_VERSION" >> $GITHUB_OUTPUT

          # Get layer ARN
          LAYER_ARN=$(aws lambda get-layer-version \
            --layer-name "$LAYER_NAME" \
            --version-number "$LAYER_VERSION" \
            --region eu-west-1 \
            --query 'LayerVersionArn' \
            --output text)

          echo "layer_arn=$LAYER_ARN" >> $GITHUB_OUTPUT
          echo "📦 Layer ARN: $LAYER_ARN"
        id: publish

      - name: Upload layer artifact
        uses: actions/upload-artifact@v4
        with:
          name: reventless-layer-${{ steps.version.outputs.version }}
          path: packages/aws-lambda-layer/builder/reventless-layer.zip
          retention-days: 90

      - name: Create release notes
        run: |
          VERSION="${{ steps.version.outputs.version }}"
          LAYER_ARN="${{ steps.publish.outputs.layer_arn }}"
          LAYER_VERSION="${{ steps.publish.outputs.layer_version }}"
          SIZE="${{ steps.verify.outputs.layer_size }}"

          cat > release-notes.md <<EOF
          # Lambda Layer for reventless-aws@$VERSION

          **Layer ARN:** \`$LAYER_ARN\`
          **Layer Version:** $LAYER_VERSION
          **Size:** $SIZE
          **Region:** eu-west-1

          ## Usage

          Add this layer to your Lambda function:

          \`\`\`bash
          aws lambda update-function-configuration \
            --function-name YOUR_FUNCTION_NAME \
            --layers $LAYER_ARN
          \`\`\`

          Or in Pulumi:

          \`\`\`typescript
          const lambda = new aws.lambda.Function("myFunction", {
            // ... other config
            layers: ["$LAYER_ARN"],
          });
          \`\`\`

          ## Compatible Runtimes

          - nodejs18.x
          - nodejs20.x

          ## Compatible Architectures

          - x86_64
          - arm64
          EOF

          echo "release_notes<<EOF" >> $GITHUB_OUTPUT
          cat release-notes.md >> $GITHUB_OUTPUT
          echo "EOF" >> $GITHUB_OUTPUT
        id: notes

      - name: Comment on release
        uses: actions/github-script@v7
        with:
          script: |
            const version = '${{ steps.version.outputs.version }}';
            const layerArn = '${{ steps.publish.outputs.layer_arn }}';
            const releaseNotes = `${{ steps.notes.outputs.release_notes }}`;

            // Find the release
            const releases = await github.rest.repos.listReleases({
              owner: context.repo.owner,
              repo: context.repo.repo
            });

            const release = releases.data.find(r =>
              r.tag_name === `@reventlessdev/reventless-aws@${version}`
            );

            if (release) {
              // Add comment to release
              await github.rest.repos.createReleaseComment({
                owner: context.repo.owner,
                repo: context.repo.repo,
                release_id: release.id,
                body: releaseNotes
              });

              console.log('✅ Added Lambda layer info to release');
            }

  summary:
    name: Build Summary
    runs-on: ubuntu-latest
    needs: [build-layer]
    if: always()
    steps:
      - name: Summary
        run: |
          echo "Lambda layer build completed"
          echo "Status: ${{ needs.build-layer.result }}"

          if [[ "${{ needs.build-layer.result }}" == "success" ]]; then
            echo "✅ Layer built and published successfully"
          else
            echo "❌ Layer build failed"
            exit 1
          fi
```

#### Option 2: Post-Release Hook in Main Release Workflow

Add a job to `.github/workflows/release.yml`:

```yaml
jobs:
  # ... existing release job ...

  build-lambda-layer:
    name: Build Lambda Layer
    runs-on: ubuntu-latest
    needs: [release]
    if: |
      success() &&
      contains(needs.release.outputs.released_packages, '@reventlessdev/reventless-aws')

    steps:
      # Similar steps as Option 1
```

#### Option 3: Separate Manual Workflow

For more control, use a workflow that requires manual approval:

```yaml
on:
  workflow_dispatch:
    inputs:
      version:
        description: 'Version to build'
        required: true
      publish_to_aws:
        description: 'Publish to AWS?'
        type: boolean
        default: false
      aws_region:
        description: 'AWS region'
        default: 'eu-west-1'
```

### AWS Publishing Configuration

#### Prerequisites

1. **AWS Credentials**: Store as GitHub Secrets
   - `AWS_ACCESS_KEY_ID`
   - `AWS_SECRET_ACCESS_KEY`

2. **IAM Policy**: Lambda layer publishing requires:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "lambda:PublishLayerVersion",
        "lambda:GetLayerVersion"
      ],
      "Resource": "arn:aws:lambda:*:*:layer:reventless-aws:*"
    }
  ]
}
```

#### Multi-Region Publishing

To publish to multiple regions:

```yaml
- name: Publish to multiple regions
  run: |
    REGIONS=("eu-west-1" "us-east-1" "us-west-2")

    for REGION in "${REGIONS[@]}"; do
      echo "Publishing to $REGION..."

      aws lambda publish-layer-version \
        --layer-name reventless-aws \
        --description "reventless-aws@$VERSION" \
        --zip-file fileb://builder/reventless-layer.zip \
        --compatible-runtimes nodejs18.x nodejs20.x \
        --compatible-architectures x86_64 arm64 \
        --region "$REGION"

      echo "✅ Published to $REGION"
    done
```

### Version Tracking

Create a `layer-versions.json` file to track published layers:

```json
{
  "layers": [
    {
      "package_version": "2.3.3",
      "layer_version": 42,
      "regions": {
        "eu-west-1": {
          "arn": "arn:aws:lambda:eu-west-1:123456789012:layer:reventless-aws:42",
          "size_mb": 31,
          "published_at": "2024-02-13T10:30:00Z"
        },
        "us-east-1": {
          "arn": "arn:aws:lambda:us-east-1:123456789012:layer:reventless-aws:42",
          "size_mb": 31,
          "published_at": "2024-02-13T10:32:00Z"
        }
      }
    }
  ]
}
```

Commit this file automatically after each build:

```yaml
- name: Update layer versions
  run: |
    # Update layer-versions.json
    jq '.layers += [{
      "package_version": "${{ steps.version.outputs.version }}",
      "layer_version": ${{ steps.publish.outputs.layer_version }},
      "regions": {...}
    }]' layer-versions.json > layer-versions-new.json

    mv layer-versions-new.json layer-versions.json

    git add layer-versions.json
    git commit -m "chore: update Lambda layer versions [skip ci]"
    git push
```

---

## Usage

### Building the Layer Locally

1. **Prepare precompiled modules** (if not already present):
```bash
cd packages/aws-lambda-layer/builder
# Build and copy precompiled modules to precompiled/ directory
```

2. **Set environment variables**:
```bash
export GITHUB_TOKEN="ghp_your_token_here"
```

3. **Run the builder**:
```bash
cd packages/aws-lambda-layer
npm run build
```

4. **Verify output**:
```bash
ls -lh builder/reventless-layer.zip
# Should show ~31MB zip file
```

### Development Tips

**Enable debug logging**:
```bash
export DEBUG='lib,lib:*'
npm run build
```

**Check layer contents**:
```bash
unzip -l builder/reventless-layer.zip | head -20
```

**Verify specific package**:
```bash
unzip -l builder/reventless-layer.zip | grep "@reventless/reventless-aws"
```

---

## Publishing to AWS

### Via AWS CLI

**Single region:**
```bash
aws lambda publish-layer-version \
  --layer-name reventless-aws \
  --description "reventless-aws@2.3.3" \
  --zip-file fileb://builder/reventless-layer.zip \
  --compatible-runtimes nodejs18.x nodejs20.x \
  --compatible-architectures x86_64 arm64 \
  --region eu-west-1
```

**Multi-region script:**
```bash
#!/bin/bash
VERSION="2.3.3"
REGIONS=("eu-west-1" "us-east-1" "us-west-2" "ap-southeast-1")

for REGION in "${REGIONS[@]}"; do
  echo "Publishing to $REGION..."

  aws lambda publish-layer-version \
    --layer-name reventless-aws \
    --description "reventless-aws@$VERSION" \
    --zip-file fileb://builder/reventless-layer.zip \
    --compatible-runtimes nodejs18.x nodejs20.x \
    --compatible-architectures x86_64 arm64 \
    --region "$REGION"

  echo "✅ Published to $REGION"
done
```

### Via AWS Console

1. Navigate to **AWS Lambda** → **Layers**
2. Click **Create layer**
3. Configure:
   - **Name**: `reventless-aws`
   - **Description**: `reventless-aws@<version>`
   - **Upload**: Select `reventless-layer.zip`
   - **Compatible runtimes**: nodejs18.x, nodejs20.x
   - **Compatible architectures**: x86_64, arm64
4. Click **Create**

### Using in Lambda Functions

**AWS CLI:**
```bash
aws lambda update-function-configuration \
  --function-name my-function \
  --layers arn:aws:lambda:eu-west-1:123456789012:layer:reventless-aws:42
```

**Pulumi:**
```typescript
const lambda = new aws.lambda.Function("myFunction", {
  runtime: aws.lambda.Runtime.NodeJS20dX,
  layers: [
    "arn:aws:lambda:eu-west-1:123456789012:layer:reventless-aws:42"
  ],
  // ... other config
});
```

**Terraform:**
```hcl
resource "aws_lambda_function" "my_function" {
  function_name = "my-function"
  runtime       = "nodejs20.x"

  layers = [
    "arn:aws:lambda:eu-west-1:123456789012:layer:reventless-aws:42"
  ]

  # ... other config
}
```

---

## Troubleshooting

### Build Issues

**Problem**: `ENOTFOUND` or authentication errors

**Solution**: Ensure `GITHUB_TOKEN` is set and has `read:packages` permission:
```bash
echo $GITHUB_TOKEN
# Should output a token starting with ghp_
```

**Problem**: Missing precompiled modules

**Solution**: Build ReScript packages locally and copy to `builder/precompiled/`:
```bash
cd /path/to/package
npm install
npm run build
cp -r lib builder/precompiled/@scope/package-name
```

**Problem**: Layer exceeds 50MB limit

**Solution**: Review excluded packages and add more to `excludeScopes` or `excludeModules`

### AWS Publishing Issues

**Problem**: `AccessDeniedException`

**Solution**: Verify IAM permissions include `lambda:PublishLayerVersion`

**Problem**: Layer not appearing in other regions

**Solution**: Layers are region-specific. Publish separately to each region.

---

## Future Improvements

- [ ] Migrate `builder/builder.js` to use `src/index.js` library
- [ ] Automate precompiled module building
- [ ] Add validation tests for layer contents
- [ ] Support alternative compression formats (e.g., gzip optimization)
- [ ] Add layer size optimization recommendations
- [ ] Implement layer caching based on dependency hashes
- [ ] Support custom AWS accounts for publishing
- [ ] Add rollback mechanism for failed deployments

---

## Related Documentation

- [AWS Lambda Layers](https://docs.aws.amazon.com/lambda/latest/dg/configuration-layers.html)
- [npm Arborist](https://www.npmjs.com/package/@npmcli/arborist)
- [Pacote](https://www.npmjs.com/package/pacote)
- [GitHub Packages](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-npm-registry)
