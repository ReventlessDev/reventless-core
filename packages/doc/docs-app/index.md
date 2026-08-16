---
title: What is Reventless?
sidebar_label: Introduction
sidebar_position: 1
---

# What is Reventless?

**Reventless is a spec-driven, event-sourced CQRS platform for serverless applications.**
You describe your domain as commands, events, and projections in type-safe
[ReScript](https://rescript-lang.org/); the framework provisions and wires the
infrastructure — queues, tables, functions, event routing, serialization, and
GraphQL and MCP APIs — with [Pulumi](https://www.pulumi.com/).

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

## Methodology

Commands and events are part of the
[ubiquitous language](https://www.martinfowler.com/bliki/UbiquitousLanguage.html)
shared between developers and domain experts. Reventless pairs this programming
model with an [Event Storming](https://en.wikipedia.org/wiki/Event_storming)-based
methodology: gather requirements with domain experts, model the domain as commands
and events, and translate directly into Reventless specs — the requirements become
the running code.

The core framework is cloud-agnostic; `reventless-aws` provides the AWS
implementation (Lambda, SQS, SNS, DynamoDB, S3), and `reventless-local` runs the
same components locally for development and testing.

## Where to go next

| Section | Who it's for |
|---|---|
| **[Why Reventless](/why/)** | Evaluating it — the model, what you provide and get, deployment options, and how it compares. No code. |
| **[Try it](/tutorials/get-started)** | The online-shop example, end to end — run locally, deploy to your own AWS account, test. |
| **[App Guide](./get-started.md)** | Building your own app — plugins, aggregates, read models, DCB slices, the GraphQL API |
| **[Infrastructure](/infrastructure)** | AWS adapters, Pulumi deployment, live updates, deploying to your own domain |
| **[Contributing](/framework/contributing)** | Framework internals and extending the framework |

The home page's [**Pick your path**](/) cards lay out the recommended reading order
for each of these audiences.
