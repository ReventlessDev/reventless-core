---
title: App Developer Guide
sidebar_position: 1
---

# Reventless — App Developer Guide

:::info Repository Structure
Reventless is organized as two separate monorepos:
- **[reventless-core](https://github.com/ReventlessDev/reventless-core)** — Framework core, AWS adapters, ReScript bindings
- **[reventless-ui](https://github.com/yourorg/reventless-ui)** — React UI components and routing

This guide covers building applications with Reventless.
:::

**Reventless** is an event-sourced CQRS framework for serverless infrastructure. It lets you focus on your business domain — commands, events, and projections — while the framework handles infrastructure, serialization, and scaling.

## What You Will Build

As an application developer you define:

- **Commands** — requests for change, named in imperative form (`CreateItem`, `RenameItem`)
- **Events** — immutable facts produced by commands, named in past tense (`ItemCreated`, `ItemRenamed`)
- **Aggregates** — command handlers that enforce invariants and emit events
- **Read Models** — projections of events into queryable state
- **Plugins** — deployment units grouping related aggregates and read models

The framework provides everything else: SQS queues, DynamoDB tables, Lambda functions, event routing, serialization, and optimistic concurrency control.

## Tech Stack

Applications built with Reventless use:

- **[ReScript](https://rescript-lang.org/)** — functional programming language that compiles to JavaScript, providing end-to-end type safety
- **[Pulumi](https://www.pulumi.com/)** — Infrastructure as Code for deploying serverless resources
- **[AWS](https://aws.amazon.com/serverless/)** — serverless infrastructure (Lambda, SQS, SNS, DynamoDB, S3)

## Core Concepts

### Commands and Events

Everything revolves around commands and events — part of the [ubiquitous language](https://www.martinfowler.com/bliki/UbiquitousLanguage.html) shared between developers and domain experts.

Commands are desires for change; they can be rejected. Events are immutable facts; they never change once recorded.

### The Reventless Methodology

Reventless pairs the programming model with an [Event Storming](https://en.wikipedia.org/wiki/Event_storming)-based methodology: gather requirements collaboratively with domain experts, model the domain as commands and events, and translate directly into Reventless specs. Zero waste — the requirements become the running code.

### Serverless and Cloud-Agnostic

The framework is designed for serverless infrastructure: pay-as-you-go, automatic scaling, no servers to manage. The core framework is cloud-agnostic; `reventless-aws` provides the AWS implementation.

## Get Productive

1. [Get started](./get-started.md) — set up your project and create your first plugin
2. [Component overview](./component-overview.md) — understand the building blocks
3. [Components reference](./components/aggregate.md) — deep-dive into each component
4. [ReScript syntax](./rescript-syntax.md) — language reference for the features used in Reventless
