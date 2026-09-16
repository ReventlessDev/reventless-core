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
2. An SSM parameter at `/reventless/layer-arn/<stack>`, looked up automatically
   through the AWS CLI in the stack's `aws:region` (the CLI's default region when
   the stack sets none) — so a local deploy needs no manual export.
3. Nothing — the deploy stops, naming the parameter and region it checked. A
   function's archive carries the plugin's own packages and leaves the
   framework's to the layer, so a function without one would fail with
   `Cannot find package` on its first invocation.

A layer belongs to one account and one region, so a new account has none until
you publish one. Every `@reventlessdev/reventless-aws` release attaches the layer
to its GitHub release as `reventless-layer.zip`. Publish the one matching the
version you deploy, and store its ARN where step 2 finds it:

```bash
VERSION="<your @reventlessdev/reventless-aws version>"
curl -fLo reventless-layer.zip \
  "https://github.com/ReventlessDev/reventless-core/releases/download/%40reventlessdev%2Freventless-aws%40${VERSION}/reventless-layer.zip"

LAYER_ARN=$(aws lambda publish-layer-version \
  --layer-name reventless-aws \
  --zip-file fileb://reventless-layer.zip \
  --compatible-runtimes nodejs20.x nodejs22.x \
  --query LayerVersionArn --output text)

aws ssm put-parameter --name "/reventless/layer-arn/<stack>" \
  --type String --overwrite --value "$LAYER_ARN"
```

Keep the layer and the package version in step: publish a new layer when you
upgrade `@reventlessdev/reventless-aws`, because a layer older than the code that
expects it fails at runtime, not at deploy. The
[Lambda layer reference](../aws-lambda-layer.md) covers what the layer contains
and how to build one yourself.

## Deploying

Build, then deploy the platform stack first and each plugin stack after it, in the
order `deploy-manifest.yaml` lists them:

```bash
pnpm run build                               # compile the plugins and deployment packages

cd platform-aws && pulumi up --stack alpha   # the platform first
cd ../catalog-aws && pulumi up --stack alpha
cd ../ordering-aws && pulumi up --stack alpha

cd ../platform-aws
pnpm exec bake-manifest --manifest ../deploy-manifest.yaml --stack alpha
```

Pulumi shows the planned changes — tables, queues, topics, functions, resolvers,
permissions — before it applies anything.

The last command writes the component manifest, the file that tells the web app
which pages to show. The discovery query it stands in for is for administrators
only, so without it every other user signs in to an empty app. It waits until each
plugin has registered the structure its stack just deployed. The reusable GitHub
Actions workflow runs the same command after its plugin stacks are up.

`deploy-app up` does all of this for a try-out stack — the layer, the stacks, the
manifest and the accounts in `.reventless/users.<stack>.yaml` — and `deploy-app
down` removes it again; the [tutorial](/tutorials/deploy-to-aws) runs it for the
example. A new stack it creates starts with the settings the app lists under
`stack-defaults` for that folder in `deploy-manifest.yaml`:

```yaml
platform:
  path: platform-aws
  stack-defaults:
    platform:messagingEmailProvider: log
```

### Your own identity provider

By default the platform creates its own Cognito user pool. To use an existing one,
set its ID — as `REVENTLESS_IDENTITY_PROVIDER_ID`, or `identityProviderId` in the
gitignored `Pulumi.local.yaml` — and provision the pool's active-role store before
the first deploy:

```bash
pnpm exec provision-identity --provider-id eu-west-1_AbCdEfGhI
```

A stack pointed at a pool whose store is missing fails the deploy.
[Bringing your own identity provider](../deployment-guide.md#bringing-your-own-identity-provider)
explains why the store belongs to the pool rather than to the stack.

### Removing a deployment

Remove the stacks in the reverse of the deploy order — plugins first, the platform
last — with `pulumi destroy --stack <stack>` in each folder. Two things stop a
destroy, both on purpose:

- **Protected object stores.** A stack that is not disposable — not named `pr-*`
  and not declaring `reventless:disposable: "true"` — gets its object-store buckets
  marked protected, so a stray refactor cannot delete uploaded files. Pulumi names
  the protected resource and refuses; `pulumi state unprotect --all --stack <stack>`
  lifts it deliberately.
- **Non-empty buckets.** The same stacks' buckets are created without force
  destroy, so S3 refuses to delete one that still holds files. Empty it first with
  `aws s3 rm s3://<bucket> --recursive`.

A stack declaring `reventless:disposable: "true"` has neither, so `pulumi destroy`
alone removes it. Never set it on a stack whose data you want to keep.

`pulumi stack rm <stack>` afterwards also deletes that stack's `Pulumi.<stack>.yaml`;
restore a tracked one with `git checkout` if you meant to keep its settings.

For the ordering rules when several plugins depend on each other, and for adding
or removing a plugin later, see the
[deployment guide](../deployment-guide.md).

## Next

- [AWS adapters overview](./index.md) — how components map to AWS services
- [Operating a deployment](../operating.md) — costs, logs, dead letters, IAM
- [Lambda deployment](../lambda-deployment.md) — handler pipeline and per-handler tuning
- [Custom domain](../custom-domain.md) — serving the UI from your own hostname
