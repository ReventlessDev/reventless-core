---
title: "Deployment: fast now, sovereign later"
sidebar_label: "Deployment: fast now, sovereign later"
sidebar_position: 4
---

# Deployment: fast now, sovereign later

Where an application runs is a deployment decision in Reventless, not an
architectural one. Your domain description says nothing about tables, queues, or
regions — so the same application can be carried to a different platform by
changing configuration rather than by being rewritten.

Today that means one production target and a clear direction of travel. Both are
stated plainly below, because picking a platform on an overstated roadmap is
nobody's idea of a good outcome.

## Available today: AWS serverless

The AWS target is the production path, and the one the framework is exercised
against continuously.

- **Provisioned for you.** The storage, queues, functions, APIs, permissions, and
  endpoints your application needs are created in *your own AWS account* from the
  same description you wrote. There is no separate infrastructure project to
  maintain.
- **Running in under an hour.** Starting from an AWS account and a checkout, the
  worked example deploys end to end without infrastructure expertise — see
  [Deploy to your own AWS account](/tutorials/deploy-to-aws).
- **Nothing to operate.** No servers, no clusters, no patching windows, no
  capacity planning. Scaling is the platform's concern.
- **Scales to zero.** Storage and compute are pay-per-request. An idle
  application costs approximately nothing, which makes running a real deployment
  per environment — or per experiment — practical.
- **Self-hosted, not a SaaS.** Reventless is open-source software deployed into
  infrastructure you own and control. There is no vendor in the request path, no
  per-seat licence, and no account to keep in good standing to keep your
  application running.

## Your data stays yours

The complete history of your business — every event, in order, with its cause —
lives in your own account, in a documented format, readable without the
framework. That matters for two reasons: you can always answer questions about
your own past with your own tools, and moving elsewhere is a data migration
rather than an archaeology project.

## In progress: sovereign cloud and your own data center

The pieces that make an application provider-independent are already in the
framework, by construction:

- **The provider seam.** The framework core contains no infrastructure code. It
  defines the surfaces an application needs — a place to append events, a channel
  to carry commands, a store to hold views — and a *provider package* implements
  them for a platform. Two providers exist today: one for AWS, one that runs
  everything in a single local process for development and tests. Your
  application code depends on neither.
- **A relational storage engine.** A Postgres storage engine implements the same
  event-log, decision, and view surfaces on a relational database, with exact
  consistency semantics and standard relational tooling. It is validated against
  a live database and can already be used on AWS-managed Postgres — see
  [Managed Postgres on AWS](/infrastructure/postgres-aws-deployment).

**What does not exist yet** is a complete sovereign platform: a provider that
runs a Reventless application end to end in a European sovereign cloud or in your
own data center, with the same one-command deployment as the AWS target. That
work is on the roadmap and actively underway; it is not shipping today, and you
should not plan a go-live on it.

**What this means for a decision now:** build on AWS serverless. When the
sovereign target ships, the part you wrote — the domain description, the
decisions, the views, the scenarios — is the part that moves unchanged. What
changes is configuration, and what travels with you is your event history.

## Development runs anywhere

Both targets share a third mode: the local platform runs the entire application —
storage, APIs, generated UI, and all — in a single process on a developer
machine, with no cloud account and no credentials. State is in memory by default
and can be kept in a local file between runs. It is the same application code as
production, which is what makes the local test suite meaningful.

## Next

- [How it compares](./how-it-compares.md)
- [See it run](/tutorials/overview) — the worked example, locally and on AWS
