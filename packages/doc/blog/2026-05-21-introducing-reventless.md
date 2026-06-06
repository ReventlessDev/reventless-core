---
slug: introducing-reventless
title: Introducing Reventless
authors: [reventless]
tags: [event-sourcing]
date: 2026-05-21
---

Reventless is an **event-sourced CQRS framework for serverless applications**.
You describe your domain as commands, events, and projections in type-safe
ReScript, and the framework provisions and wires the serverless infrastructure —
queues, tables, functions, event routing, and a GraphQL API — with Pulumi.

<!-- truncate -->

## Why another framework?

Event sourcing and CQRS give you a full audit trail, time-travel, and a clean
separation of writes from reads. On serverless they also give you a lot of
plumbing: command queues, idempotent event logs with optimistic concurrency,
fan-out to projections, read tables, subscriptions, and the IAM and deployment
glue that holds it together.

Reventless removes that plumbing. You write the domain logic; the framework
generates the serverless infrastructure and the runtime that connects it. The
core is cloud-agnostic — `reventless-aws` provides the AWS implementation, and
`reventless-local` runs the same components locally for development and
testing.

## The programming model

A **command** is a request to change something; an **aggregate** (or a **DCB
slice**) decides whether to accept it and emits **events**. Events are immutable
facts stored in an event log and broadcast to **read models**, which project them
into queryable state. A **plugin** groups related aggregates and read models into
one deployable unit, and **extension points** let plugins communicate without
depending on each other's source.

## Where to start

- New here? Read [What is Reventless?](/app/) for the full orientation.
- Want to see it work? Follow the [tutorial](/tutorials/get-started) — understand
  the example, run it locally, deploy it to AWS, and test it.
- Building something? The [App Guide](/app/get-started) walks through your first
  plugin.
