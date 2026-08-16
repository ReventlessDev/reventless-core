---
title: Getting Started with AWS
---

# Deploying a plugin on AWS

Your application code does not change to run on AWS. What you add is a small
**deployment package** per plugin (and one for the platform), each of which is a
Pulumi project whose entry point builds your plugin over the AWS platform.

If you want to see this working before building your own, deploy the shipped
example first: [Deploy the online shop to your AWS account](/tutorials/deploy-to-aws).

## Prerequisites

- An AWS account and credentials that can create the services the framework
  provisions — see
  [what the deploying principal needs](../operating.md#what-the-deploying-principal-needs).
- [Pulumi CLI](https://www.pulumi.com/docs/install/) and a Pulumi account or a
  self-managed backend.
- Node.js 22.17.1 and pnpm 10.

## The shape of a deployment package

One package per plugin, named `<plugin>-aws`, sitting beside the plugin it
deploys:

```
my-app/
├── catalog/            # the plugin — specs, behaviors, scenarios
├── catalog-aws/        # its deployment package
│   ├── src/Main.res    # generated entry point
│   ├── Pulumi.yaml
│   ├── Pulumi.<stack>.yaml
│   ├── rescript.json
│   └── package.json
└── platform-aws/       # the platform stack, deployed first
```

The deployment package depends on the plugin, on `@reventlessdev/reventless-aws`,
and on the spec packages of any plugin it integrates with:

```bash
pnpm add @reventlessdev/reventless-aws @reventlessdev/reventless-infra \
         @reventlessdev/reventless-spec sury
```

Its `Pulumi.yaml` points `main` at the compiled entry point, because the project
is ReScript rather than TypeScript:

```yaml
name: my-app-catalog-aws
runtime: nodejs
main: src/Main.res.mjs
description: My app — Catalog plugin stack
```

## The entry point is generated

`src/Main.res` is written for you by `generate-plugin` before each build, the
same generator that writes the plugin's composition root:

```json
{
  "scripts": {
    "generate": "generate-plugin --aws CatalogPlugin ../catalog/src/",
    "prebuild": "pnpm run generate",
    "build": "rescript build"
  }
}
```

What it produces is short, and worth reading once because it is the whole
deploy-time story:

```rescript
ReventlessInfra.DeployBootstrap.run(PreDeploy)

module Platform = ReventlessAws.Platform.Make()
module Catalog = Plugin.Make(Platform)

let default = Platform.deployPlugin(~plugin=module(Catalog))

ReventlessInfra.DeployBootstrap.run(PostDeploy)
```

The plugin is a functor over the platform — the same functor the local platform
applies. Swapping `ReventlessAws.Platform` for `ReventlessLocal.Platform` is the
entire difference between the two deployments.

## The platform stack comes first

The platform stack owns what plugins share: the AppSync API, the admin
components, the scheduler, the Lambda layer reference, and (optionally) the host
UI. Deploy it once; plugins deploy independently afterwards and register their
GraphQL schema fragment with it **at runtime**, so adding a plugin needs no
platform redeploy.

```rescript
module Platform = ReventlessAws.Platform.Make()

let default = Platform.deployPlatform(
  ~version=Reventless.PackageVersion.fromCaller(),
)
```

## Stack configuration

Per-stack settings live in `Pulumi.<stack>.yaml`. A plugin stack needs to know
which platform stack it belongs to, and which other plugin stacks it depends on:

```yaml
config:
  aws:region: eu-west-1
  platform:stack: <your-pulumi-org>/my-app-platform-aws/alpha
  interstack:
    dependencies:
      - <your-pulumi-org>/my-app-catalog-aws/alpha
```

Stack names are `<org>/<project>/<stack>`. The
[deployment guide](../deployment-guide.md) covers the full key list, the
environment-variable equivalents for CI, and how cross-plugin extension wiring
is resolved.

## The Lambda layer

Framework code ships to Lambda as a shared layer rather than being bundled into
every function, which keeps deployment packages small and cold starts short. The
layer ARN is resolved at deploy time in this order:

1. `REVENTLESS_LAYER_ARN`, if set — the fast path, and what CI uses.
2. An SSM parameter at `/reventless/layer-arn/<stack>`, looked up automatically —
   so a local deploy needs no manual export.
3. Nothing — functions deploy without the layer, bundling their dependencies
   instead. This works, but produces larger packages and slower cold starts.

Each release of `@reventlessdev/reventless-aws` publishes a matching layer. Keep
the layer and the package version in step: a layer older than the code that
expects it fails at runtime, not at deploy.

## Deploying

```bash
pnpm run build          # compile the plugin and its deployment package
pulumi up --stack alpha
```

Pulumi shows the planned changes — tables, queues, topics, functions, resolvers,
permissions — before it applies anything.

For the ordering rules when several plugins depend on each other, and for adding
or removing a plugin later, see the
[deployment guide](../deployment-guide.md).

## Next

- [AWS adapters overview](./index.md) — how components map to AWS services
- [Operating a deployment](../operating.md) — costs, logs, dead letters, IAM
- [Lambda deployment](../lambda-deployment.md) — handler pipeline and per-handler tuning
- [Custom domain](../custom-domain.md) — serving the UI from your own hostname
