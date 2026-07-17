---
title: Getting Started with AWS
sidebar_position: 2
---

# Getting Started with reventless-aws

This guide covers setting up and deploying a Reventless application on AWS using `reventless-aws`.

## Prerequisites

- An AWS account with appropriate permissions
- [Pulumi CLI](https://www.pulumi.com/docs/install/) installed and configured
- Node.js 22.17.1 (see `.node-version` for exact version)
- ReScript development setup (see the [App Developer Guide](/app/get-started))

## Install Dependencies

In your Reventless application project:

```bash
npm install @reventless/reventless @reventless/aws @reventless/spec
```

## Project Structure

A typical Reventless AWS project looks like:

```
my-app/
├── infra/            # Pulumi infrastructure (deploy-time)
│   ├── index.ts      # Entry point: creates the core, plugins
│   └── Pulumi.yaml   # Pulumi project config
├── src/              # Application logic (ReScript)
│   ├── MyAggregate.res
│   ├── MyReadModel.res
│   └── MyPlugin.res
├── rescript.json
└── package.json
```

## Configure Pulumi

```yaml
# Pulumi.yaml
name: my-reventless-app
runtime: nodejs
description: My Reventless application on AWS
```

Set your AWS region:

```bash
pulumi config set aws:region us-east-1
```

## Platform Admin Components

The platform admin components (Plugin aggregate, Plugin read model, Plugin extension point) are created internally by `makePlatform` — they provide shared infrastructure for plugins to communicate. You don't need to create them manually.

## Create a Plugin

```rescript
// MyPlugin.res
module Plugin = ReventlessAws.Plugin.Make({
  let name = "my-plugin"
  let version = "1.0.0"
})

let plugin = Plugin.make(
  ~name="my-plugin",
  ~version="1.0.0",
  ~aggregates=[module(MyAggregate)],
  ~readModels=[module(MyReadModel)],
)
```

## Lambda Layer

Reventless applications use a shared Lambda layer containing `@reventlessdev/reventless-aws` and all its dependencies. This keeps individual Lambda deployment packages small and speeds up cold starts.

### Finding the Layer ARN

Each release of `@reventlessdev/reventless-aws` automatically builds and publishes a Lambda layer. The layer ARN is appended to the GitHub release notes:

1. Go to the [reventless-core releases](https://github.com/ReventlessDev/reventless-core/releases)
2. Find the release for your `@reventlessdev/reventless-aws` version
3. Copy the **Lambda Layer ARN** from the release notes

### Configuring the Layer

Set the `REVENTLESS_LAYER_ARN` environment variable when running `pulumi up`. All Lambda functions created by Reventless will automatically include this layer:

```bash
REVENTLESS_LAYER_ARN="arn:aws:lambda:eu-west-1:123456789:layer:reventless-aws:1" pulumi up
```

For a more permanent setup, add it to your Pulumi stack configuration:

```yaml
# Pulumi.<stack>.yaml
config:
  aws:region: eu-west-1
```

```bash
# Set in your shell profile or CI environment
export REVENTLESS_LAYER_ARN="arn:aws:lambda:eu-west-1:123456789:layer:reventless-aws:1"
```

The layer ARN is read at deploy-time by `rescript-pulumi-aws` and passed to every Lambda function's `layers` configuration. If `REVENTLESS_LAYER_ARN` is not set, Lambda functions are deployed without a layer (all dependencies bundled in the deployment package).

## Deploy

```bash
cd infra
pulumi up
```

Pulumi will show the planned infrastructure changes — DynamoDB tables, SQS queues, SNS topics, Lambda functions — and ask for confirmation before deploying.

## AWS Service Costs

Reventless uses serverless AWS services with pay-per-use pricing:

- **DynamoDB** — per read/write request (on-demand mode)
- **SQS** — per message (first 1M requests/month free)
- **SNS** — per notification (first 1M/month free)
- **Lambda** — per invocation (first 1M/month free)

For typical development and low-traffic production workloads, costs are negligible.

## Testing AWS Adapters

The `reventless-aws/__tests__` directory contains tests for adapters and utilities. Tests verify both deploy-time resource creation and runtime operation logic.

When developing custom adapters or modifying existing ones, ensure:
- Deploy-time code creates resources with correct properties
- Runtime functions handle success and error cases
- IAM permissions are correctly configured
- Resources are properly tagged for cost tracking

## Next Steps

- [AWS Adapters Overview](./index.md) — understand how components map to AWS services
- [EventLog Adapter](./adapters/eventlog.md) — event storage on DynamoDB
- [CommandTopic Adapter](./adapters/commandtopic.md) — command queuing on SQS FIFO
- [QueryDb Adapter](./adapters/querydb.md) — read model storage on DynamoDB
