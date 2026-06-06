---
title: What is Reventless?
sidebar_label: Introduction
sidebar_position: 1
---

# What is Reventless?

**Reventless is an event-sourced CQRS framework for serverless applications.**
You describe your domain as commands, events, and projections in type-safe
[ReScript](https://rescript-lang.org/); the framework provisions and wires the
infrastructure — queues, tables, functions, event routing, serialization, and a
GraphQL API — with [Pulumi](https://www.pulumi.com/).

:::info Packages
The framework core, AWS adapters, and ReScript bindings live in
[reventless-core](https://github.com/ReventlessDev/reventless-core). The React
host-shell UI and routing utilities ship as the `reventless-ui` package family,
consumed by name — you don't need its source to build an app.
:::

## The problem it solves

Event sourcing and CQRS give you a full audit trail, time-travel, and a clean
separation between writes and reads. On serverless infrastructure they also give
you a great deal of plumbing: command queues, idempotent event logs with
optimistic concurrency, fan-out to projections, read tables, subscriptions, and
the IAM and deployment glue that holds it together.

Reventless removes that plumbing. You write the domain logic; the framework
generates the serverless infrastructure and the runtime that connects it.

## The programming model in three sentences

A **command** is a request to change something; an **aggregate** (or a **DCB
slice**) decides whether to accept it and emits **events**. Events are immutable
facts stored in an event log and broadcast to **read models**, which project
them into queryable state. A **plugin** groups related aggregates and read models
into one deployable unit, and **extension points** let plugins communicate
without depending on each other's source.

## Who it's for

| You are… | Start with |
|---|---|
| **Evaluating** Reventless — "what is this, should I use it?" | This page, then the [Tutorial overview](/tutorials/get-started) |
| **Building an app** on Reventless | The [Tutorial spine](/tutorials/get-started), then the [App Guide](./get-started.md) |
| **Contributing** to the framework itself | The [Contributing guide](/framework/get-started) |

## Three doorways

- **[Try the example →](/tutorials/get-started)** — follow the online-shop
  tutorial: understand it, run it locally, deploy it to AWS, and test it.
- **[Build an app →](./get-started.md)** — set up your own project and create
  your first plugin, aggregate, and read model.
- **[Contribute →](/framework/get-started)** — framework internals and how to
  extend Reventless with new components, adapters, and providers.

## Reading paths

Pick the path that matches your goal:

- **Evaluator:** Introduction (this page) → [Tutorial overview](/tutorials/get-started)
  → [Hybrid walkthrough](/tutorials/hybrid-based).
- **App developer:** the Tutorial spine (understand → run locally → deploy to AWS
  → test) → [App Guide](./get-started.md) → [Infrastructure](/infrastructure)
  for deploying to your own domain.
- **Contributor:** [Contributing get-started](/framework/get-started) → framework
  internals (ordered) → component-structure pattern → extending the framework.

## How Reventless works

Everything revolves around commands and events — part of the
[ubiquitous language](https://www.martinfowler.com/bliki/UbiquitousLanguage.html)
shared between developers and domain experts. Commands are desires for change
and can be rejected; events are immutable facts that never change once recorded.

Reventless pairs this programming model with an
[Event Storming](https://en.wikipedia.org/wiki/Event_storming)-based methodology:
gather requirements collaboratively with domain experts, model the domain as
commands and events, and translate directly into Reventless specs — the
requirements become the running code.

The core framework is cloud-agnostic; `reventless-aws` provides the AWS
implementation (Lambda, SQS, SNS, DynamoDB, S3), and `reventless-local`
runs the same components locally for development and testing.

## The documentation sections

| Section | Who it's for |
|---|---|
| **Introduction** (this page) | Newcomers — what Reventless is and where to start |
| **[Tutorial](/tutorials/get-started)** | The online-shop example, end to end — understand, run, deploy, test |
| **[App Guide](./get-started.md)** | Building your own app — plugins, aggregates, read models, DCB slices, the GraphQL API |
| **[Infrastructure](/infrastructure)** | AWS adapters, Pulumi deployment, live updates, your own domain |
| **[Contributing](/framework/get-started)** | Framework internals and extending the framework |
