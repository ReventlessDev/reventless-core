[![npm](https://img.shields.io/npm/v/@reventlessdev/reventless-aws.svg?label=npm)](https://www.npmjs.com/package/@reventlessdev/reventless-aws)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Docs](https://img.shields.io/badge/docs-reventless.dev-blue)](https://docs.reventless.dev)

# @reventlessdev/reventless-aws

> ⚠️ **Alpha.** APIs and on-disk formats can change without notice between releases.
> Pin exact versions and expect breaking changes.

The **AWS adapter** for [Reventless](https://docs.reventless.dev) — a
spec-driven, event-sourced CQRS framework written in [ReScript](https://rescript-lang.org).
This package binds the provider-agnostic components of
[`@reventlessdev/reventless-core`](https://www.npmjs.com/package/@reventlessdev/reventless-core)
to concrete AWS resources and provisions them with [Pulumi](https://www.pulumi.com/),
so the same domain code deploys to AWS unchanged. It covers both deploy-time
(infrastructure) and runtime (Lambda handlers).

## What it provides

ReScript modules, consumed by adding the package to your `rescript.json` `dependencies`:

- **`Platform`** — the AWS platform functor (`Platform.Make()` / `Platform.MakeWithConfig({...})`).
  Applying it wires up AWS builders once; your plugin functor then takes only the
  application-defined `Spec`, `Behavior`, and `Mappings`.
- **Component builders** (`Aggregate_Builder`, `ReadModel_Builder`, `Plugin`,
  the slice builders, `Task_Builder`, `Counter_Builder`, `Scheduler`, …) —
  AWS-preconfigured versions of the core hierarchical components, including the
  Single / PerAggregate / Micro runtime layouts.
- **Adapters** (`src/adapter/`) — the AWS implementation of each core adapter
  interface, one per component (`EventLog`, `CommandTopic`, `EventTopic`,
  `EventCollector`, `QueryDb`, `Counter`, `ScheduledPublisher`, `Task`, …).
- **`util/`** — AWS-resource helpers shared across adapters (DynamoDB, Lambda,
  SQS/SNS FIFO, S3, IAM, AppSync, Cognito, VPC, CloudWatch).

The adapters map core components onto AWS services:

| Core component            | AWS resource            |
|---------------------------|-------------------------|
| EventLog / QueryDb        | DynamoDB                |
| CommandTopic / EventTopic | SQS (FIFO), SNS         |
| Runtime handlers          | Lambda                  |
| Task buckets              | S3                      |
| Domain API                | AppSync (GraphQL)       |

## Where it fits

`reventless-aws` is a storage/cloud **adapter** for the Reventless framework.
[`reventless-core`](https://www.npmjs.com/package/@reventlessdev/reventless-core)
is provider-agnostic; you pair it with exactly one platform adapter at deploy time:

- [`@reventlessdev/reventless-aws`](https://www.npmjs.com/package/@reventlessdev/reventless-aws) — **this package** (DynamoDB, Lambda, SQS, SNS, S3)
- [`@reventlessdev/reventless-postgres`](https://www.npmjs.com/package/@reventlessdev/reventless-postgres) — Postgres event log + query DB
- [`@reventlessdev/reventless-local`](https://www.npmjs.com/package/@reventlessdev/reventless-local) — in-memory / SQLite platform for local dev and tests

It also depends on [`reventless-postgres`](https://www.npmjs.com/package/@reventlessdev/reventless-postgres)
so a deployment can back its event logs with managed Postgres (RDS/Aurora)
instead of DynamoDB, and on
[`reventless-infra`](https://www.npmjs.com/package/@reventlessdev/reventless-infra) /
[`reventless-spec`](https://www.npmjs.com/package/@reventlessdev/reventless-spec)
for the shared infrastructure and specification types.

You normally obtain `reventless-aws` by scaffolding an app rather than installing
it on its own.

## Install

```bash
pnpm add @reventlessdev/reventless-aws
```

Then register it as a ReScript dependency in `rescript.json`:

```json
{
  "dependencies": ["@reventlessdev/reventless-aws"]
}
```

Requires ReScript `^12.3.0` (peer dependency).

## Links

- 📚 Documentation — [docs.reventless.dev](https://docs.reventless.dev)
- 📦 Repository — [ReventlessDev/reventless-core](https://github.com/ReventlessDev/reventless-core)
- 📋 [Changelog](./CHANGELOG.md)

## License

[Apache-2.0](https://opensource.org/licenses/Apache-2.0)
