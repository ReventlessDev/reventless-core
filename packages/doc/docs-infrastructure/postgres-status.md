---
title: Postgres storage — status
sidebar_label: Postgres storage (status)
---

# Postgres storage: what exists today

Reventless has a relational storage engine — `@reventlessdev/reventless-postgres`
— implementing the same storage surfaces the DynamoDB path implements. This page
is the honest summary of what it covers, so you can tell what you can build on
and what you cannot.

For the deployment mechanics on AWS-managed Postgres (what gets provisioned, VPC
and secrets, pooling, cost), see
[Managed Postgres on AWS](./postgres-aws-deployment.md).

## What it covers

| Surface | Status |
|---|---|
| Classic event log (per-aggregate) | Implemented, live-validated |
| DCB event log (events, tags, conditional append) | Implemented, live-validated |
| QueryDb (read models and their query paths) | Implemented, live-validated |
| Change feeds for both logs | Implemented — an in-table read fenced on transaction visibility, woken by database notification, with a low-frequency fallback tick |

The engine is connection-string driven: RDS, Aurora, any managed provider, or a
container on your laptop.

## Why you might want it

Two reasons, both about the write path:

- **Exact DCB semantics.** A conditional append evaluates the real tag query
  atomically inside one transaction. The DynamoDB path emulates the same
  condition with per-tag fence sentinel rows — correct, but an emulation.
- **Monotonic positions.** Cursors are monotonic by construction, so a
  checkpointing reader can never skip an event that committed late.

Plus the ordinary benefits of a relational store: `psql`, standard backups and
point-in-time recovery, and the tooling your operations team already has.

## What it costs

Postgres is **additive, not a replacement** — DynamoDB remains the default, and a
platform can put some surfaces on Postgres and leave others on DynamoDB. The
trade is real:

- An always-on instance inside a VPC, rather than a serverless store that scales
  to zero. Even Aurora Serverless v2 scales down, not to nothing.
- VPC network interfaces add cold-start latency to the functions that touch it.
- Reads route through an in-VPC resolver rather than straight from the API to the
  table.

Reach for it when you need the exact append semantics or the relational tooling,
and accept the always-on cost. Stay on DynamoDB for the zero-VPC, scale-to-zero
default.

## What is not exercised yet

Called out so nobody discovers it during a go-live: RDS Proxy provisioning,
Aurora, and the live AWS boundary are wired but not yet exercised on a running
stack. The storage engine itself is validated against a live database.

## Relationship to the sovereign roadmap

A relational engine is one of the two pieces that make a Reventless application
portable off a single cloud — the other is the provider seam, which keeps
infrastructure out of the framework core and application code. Both exist. What
does **not** exist yet is a complete provider that runs an application end to end
outside AWS with the same one-command deployment. See
[Deployment: fast now, sovereign later](/why/deployment) for where that stands.
