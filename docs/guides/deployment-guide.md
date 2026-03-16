# Deployment Guide

This guide explains how to deploy a Reventless application with independent per-plugin deployment using Pulumi and GitHub Actions.

## Overview

A Reventless application is deployed as **one Pulumi stack per plugin** plus a **platform stack**:

- **Platform stack** — deploys shared resources: AppSync API, admin components, scheduler, Lambda Layer
- **Plugin stacks** — each plugin deploys its own infrastructure (DynamoDB tables, SQS queues, Lambda functions, etc.) and registers its GraphQL schema fragment with the platform API

Only changed plugins are deployed on each push. The git branch name determines which environment to deploy to.

## Repository Structure

Each plugin and the platform package contain a `deploy/` directory with platform-specific Pulumi programs:

```
my-app/
├── catalog-spec/                             # Spec package (no deployment)
├── catalog/
│   ├── src/CatalogPlugin.res                 # Plugin code (platform-agnostic)
│   └── deploy/
│       └── aws/
│           ├── Pulumi.yaml                   # Project definition
│           ├── Pulumi.dev.yaml               # Dev environment config
│           ├── Pulumi.prod.yaml              # Prod environment config
│           └── Main.res                      # Deploys this plugin on AWS
├── ordering-spec/
├── ordering/
│   ├── src/OrderingPlugin.res
│   └── deploy/
│       └── aws/
│           ├── Pulumi.yaml
│           ├── Pulumi.dev.yaml
│           ├── Pulumi.prod.yaml
│           └── Main.res
├── platform/
│   ├── src/Main.res                          # In-memory dev server (all plugins)
│   └── deploy/
│       └── aws/
│           ├── Pulumi.yaml
│           ├── Pulumi.dev.yaml
│           ├── Pulumi.prod.yaml
│           └── Main.res                      # Deploys platform (admin, scheduler, API)
├── deploy-manifest.yaml
├── package.json
└── .github/workflows/deploy-aws.yml
```

## Setup

### 1. Create `deploy-manifest.yaml`

At the repo root, create a manifest that maps plugin names to their source paths and deploy directories:

```yaml
# deploy-manifest.yaml
platform:
  deploy-dir: platform/deploy/aws

plugins:
  catalog:
    source-paths:
      - catalog/
      - catalog-spec/
    deploy-dir: catalog/deploy/aws
    depends-on: []

  ordering:
    source-paths:
      - ordering/
      - ordering-spec/
    deploy-dir: ordering/deploy/aws
    depends-on:
      - catalog
```

The `depends-on` field declares deployment ordering — ordering deploys after catalog because it subscribes to catalog's ExtensionPoint.

### 2. Add `deploy/aws/` to each package

Each plugin and the platform package needs a `deploy/aws/` directory with:

```
deploy/aws/
├── Pulumi.yaml              # Project name + runtime
├── Pulumi.dev.yaml          # Config for dev branch
├── Pulumi.prod.yaml         # Config for prod branch
└── Main.res                 # Entry point
```

**`Pulumi.yaml`** (shared across all environments):
```yaml
name: my-app-catalog
runtime: nodejs
description: Catalog plugin — AWS deployment
```

**`Pulumi.dev.yaml`**:
```yaml
config:
  aws:region: eu-west-1
  my-app-catalog:platformStack: org/my-app-platform/dev
  my-app-catalog:lambdaMemory: 256
  my-app-catalog:dynamoDbBillingMode: PAY_PER_REQUEST
```

**`Pulumi.prod.yaml`**:
```yaml
config:
  aws:region: eu-west-1
  my-app-catalog:platformStack: org/my-app-platform/prod
  my-app-catalog:lambdaMemory: 1024
  my-app-catalog:dynamoDbBillingMode: PROVISIONED
  my-app-catalog:dynamoDbReadCapacity: 100
  my-app-catalog:dynamoDbWriteCapacity: 50
```

**`Main.res`** (plugin entry point):
```rescript
module Platform = ReventlessAws.Platform.Make({
  let api = ...
  let apiRole = ...
})

module Catalog = CatalogPlugin.CatalogPlugin.Make(Platform)

Platform.deployPlugin(
  ~version=Reventless.PackageVersion.fromCwd(),
  ~plugin=module(Catalog),
)
```

The platform `Main.res` calls `Platform.deployPlatform()` instead.

### 3. Add the GitHub Actions workflow

Create `.github/workflows/deploy-aws.yml`:

```yaml
name: Deploy (AWS)

on:
  push:
    branches: ['**']
  pull_request:
    branches: ['**']
  workflow_dispatch:

jobs:
  deploy:
    uses: ReventlessDev/reventless-core/.github/workflows/deploy-reventless-aws.yml@main
    with:
      manifest: deploy-manifest.yaml
      node-version: "22.17.1"
    secrets:
      PULUMI_ACCESS_TOKEN: ${{ secrets.PULUMI_ACCESS_TOKEN }}
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
      NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
```

The reusable workflow handles everything: change detection, environment selection, deployment ordering, and secret resolution.

### 4. Configure GitHub secrets

Go to your GitHub repo → **Settings** → **Secrets and variables** → **Actions** → **Repository secrets** and add:

| Name | Value | Purpose |
|---|---|---|
| `PULUMI_ACCESS_TOKEN` | Your Pulumi access token | Authenticates Pulumi CLI |
| `AWS_ACCESS_KEY_ID` | IAM access key | AWS authentication |
| `AWS_SECRET_ACCESS_KEY` | IAM secret key | AWS authentication |
| `NPM_TOKEN` | GitHub/npm token | Install `@reventlessdev/*` packages |

### 5. Done

Push to `dev` → deploys to the `dev` stack. Push to `prod` → deploys to the `prod` stack. Open a PR → runs `pulumi preview` as a dry run. Only changed plugins deploy.

## Environments

### Branch name = Pulumi stack name

The git branch name is used **directly** as the Pulumi stack name. There is no hardcoded mapping. Deployment only happens if a `Pulumi.<branch>.yaml` file exists in the plugin's `deploy/aws/` directory.

- Push to `dev` → looks for `Pulumi.dev.yaml` → deploys if found
- Push to `prod` → looks for `Pulumi.prod.yaml` → deploys if found
- Push to `feature-xyz` → no `Pulumi.feature-xyz.yaml` → skipped

### Branch naming convention

Branches must be named after the environment they deploy to. The `main` branch is **not** used for active development in customer projects.

| Branch | Environment | Purpose |
|---|---|---|
| `dev` | Development | Active development, frequent deploys |
| `test` | Test | Pre-production verification |
| `prod` | Production | Stable releases only |

Feature branches (e.g., `feature-xyz`) have no `Pulumi.<branch>.yaml` and never trigger deployment.

### Adding or removing environments

| Action | What to do | Workflow change needed? |
|---|---|---|
| Add `test` environment | Create `test` branch + `Pulumi.test.yaml` in every `deploy/aws/` dir | No |
| Add temporary `demo` environment | Create `demo` branch + `Pulumi.demo.yaml` in relevant deploy dirs | No |
| Remove `dev` environment | Delete `Pulumi.dev.yaml` files | No |
| Feature branches | Don't create `Pulumi.<branch>.yaml` → no deploy | No |

### Disabling deployment on a branch

To temporarily disable deployment without losing the configuration, rename the file:

```bash
# Disable prod deployment for catalog
mv catalog/deploy/aws/Pulumi.prod.yaml catalog/deploy/aws/Pulumi.prod.yaml.disabled

# Re-enable
mv catalog/deploy/aws/Pulumi.prod.yaml.disabled catalog/deploy/aws/Pulumi.prod.yaml
```

This is git-tracked, per-plugin granular, and reversible.

| Scope | How to disable |
|---|---|
| One plugin on one branch | Rename that plugin's `Pulumi.<branch>.yaml` to `.disabled` |
| All plugins on one branch | Rename all `Pulumi.<branch>.yaml` files to `.disabled` |
| One plugin on all branches | Rename all `Pulumi.*.yaml` files in that plugin's deploy dir |
| Skip one commit | Include `[skip deploy]` in the commit message |

### Stack naming

Each plugin and the platform get their own Pulumi stack per environment:

```
org/my-app-platform/dev       org/my-app-platform/test       org/my-app-platform/prod
org/my-app-catalog/dev        org/my-app-catalog/test        org/my-app-catalog/prod
org/my-app-ordering/dev       org/my-app-ordering/test       org/my-app-ordering/prod
```

## API Schema Registration

Each plugin generates a GraphQL schema fragment and registers it dynamically with the platform's AppSync API:

1. During deployment, the plugin derives its schema from its aggregate commands and read model states
2. The plugin pushes its fragment to the platform API
3. The platform stitches all plugin fragments into a unified schema
4. When a plugin redeploys with changed schema, the platform API updates automatically

This means adding a field to a read model or a new command only requires redeploying that plugin — no platform redeployment needed.

## Secret Management

### Repository secrets (platform-wide defaults)

Set once — used by all plugins unless overridden:

| Name | Value | Purpose |
|---|---|---|
| `PULUMI_ACCESS_TOKEN` | Default Pulumi token | Authenticates Pulumi CLI for all stacks |
| `AWS_ACCESS_KEY_ID` | IAM access key | AWS authentication |
| `AWS_SECRET_ACCESS_KEY` | IAM secret key | AWS authentication |
| `NPM_TOKEN` | Package registry token | Install `@reventlessdev/*` packages |

### Per-plugin secret overrides (optional)

To use different credentials for a specific plugin:

1. Go to **Settings** → **Environments** → **New environment**
2. Name it `deploy-<plugin>` (e.g., `deploy-catalog`)
3. Add environment secrets with the same names (e.g., `PULUMI_ACCESS_TOKEN`)
4. These override the repository secrets for that plugin's deployment job

| Environment | `PULUMI_ACCESS_TOKEN` | `AWS_ACCESS_KEY_ID` | `AWS_SECRET_ACCESS_KEY` |
|---|---|---|---|
| `deploy-platform` | (repo default) | (repo default) | (repo default) |
| `deploy-catalog` | custom token | custom key | custom secret |
| `deploy-ordering` | (repo default) | (repo default) | (repo default) |

### What goes where

| What | Where | Why |
|---|---|---|
| AWS region, memory, capacity | `Pulumi.<branch>.yaml` (committed) | Non-secret, per-environment |
| Platform stack reference | `Pulumi.<branch>.yaml` (committed) | Points to correct env's platform |
| Feature flags | `Pulumi.<branch>.yaml` (committed) | Per-environment behavior |
| Access tokens, keys | GitHub secrets (never committed) | Authentication credentials |
| Database passwords | `pulumi config --secret` (encrypted in state) | Encrypted per-stack |

**Never** commit secrets to `.env`, `Pulumi.<branch>.yaml`, or any file in the repo.

## Multi-Platform Support

Plugins are platform-agnostic. To deploy to a different cloud provider, add a `deploy/<platform>/` directory:

```
catalog/deploy/
├── aws/          # Uses reventless-aws
├── azure/        # Would use a future reventless-azure
└── supabase/     # Would use a future reventless-supabase
```

Each platform directory is a self-contained Pulumi project. Plugin source code is shared — only the entry point differs.

## Deployment Behavior

### What triggers deployment

| Event | Action |
|---|---|
| Push to a branch with `Pulumi.<branch>.yaml` | Deploy changed plugins |
| Push to a branch without `Pulumi.<branch>.yaml` | No deployment |
| Pull request | `pulumi preview` (dry run, posted as PR comment) |
| Commit message contains `[skip deploy]` | No deployment |
| Platform framework packages changed | Platform + all plugins deploy |
| Only one plugin's source changed | Only that plugin deploys |

### Deployment order

1. **Platform first** — if platform changed, deploys before any plugins
2. **Plugins in parallel** — independent plugins deploy concurrently
3. **Dependent plugins sequentially** — respects `depends-on` in the manifest

### Manual deployment

```bash
# Deploy catalog to dev
pulumi up --stack dev --cwd catalog/deploy/aws/

# Preview what would change in prod
pulumi preview --stack prod --cwd catalog/deploy/aws/
```

## Reference Implementation

The `examples/online-shop-hybrid/` directory in the reventless-core repo contains a working reference implementation with deployment configured. It follows the same patterns described in this guide.
