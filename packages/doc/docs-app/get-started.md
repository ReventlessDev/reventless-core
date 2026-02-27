---
title: Get Started
date: 2021-11-22
draft: false
sidebar_position: 2
---

## Basics

When implementing a system based on Reventless you should only think about `commands` and `events`. These provide easy to understand reasoning for anything happening.  
Great care should go into naming these according to the [ubiquitous language](https://www.martinfowler.com/bliki/UbiquitousLanguage.html) of the project / context.  
`Command`s are usually named in imperative, while `event`s are usually named in past tense. (e.g: doSomething vs somethingDone).

Since `command`s are only a formulated desire for change, they can potentially be rejected with an `error`. `Event`s are absolute facts and the result of `command`s, which will never change once issued.

## ReScript and Sury

### ReScript

Reventless is written in [ReScript](https://rescript-lang.org), a strongly-typed language that compiles to JavaScript. Its variant types, exhaustive pattern matching, and module system are used throughout the framework to model commands, events, and state machines in a way that the compiler can fully verify.

See [ReScript Syntax](./rescript-syntax.md) for an overview of the language features you will encounter most often.

### Sury

[Sury](https://github.com/DZakh/sury) is a JSON serialization library for ReScript that Reventless uses. Annotate a type with `@schema` and Sury generates codecs automatically—no hand-written serialization required.

See [ReScript Syntax](./rescript-syntax.md#ppx) for details on `@schema` and `@s.matches` annotations.

## Development Setup

### Install VS Code

- install [Visual Studio Code](https://code.visualstudio.com)
- install [ReScript](https://marketplace.visualstudio.com/items?itemName=rescript-ide.rescript-vscode) (extension id: `rescript-ide.rescript-vscode`)

### Install Node

- install [Node.js 22.x](https://nodejs.org/) (LTS version as of 2025)

### Initialize a new Project

Run `npm init` in the directory you want to create the new project and answer all questions.

Add build scripts to your `package.json`:

```json
{
  "scripts": {
    "build": "rescript build",
    "clean": "rescript clean",
    "start": "rescript build -w"
  }
}
```

### Install Dependencies

Add the Reventless packages, the ReScript compiler, and Sury to your project, then install them:

```bash
npm install @reventless/reventless @reventless/reventless-spec
npm install --save-dev rescript sury
npm install
```

### Choose a Cloud Provider

The Reventless-Framework is cloud-provider agnostic. Therefore there is a different package per provider, which contains pre-configured default components and the necessary adapters to configure the components yourself when needed.  
The packages are called `@reventless/reventless-<providerName>` (e.g. `@reventless/reventless-aws`)

> Currently we support only AWS out of the box, but plan to increase the supported provider in the future.

Choose the according package and install it by running e.g. `npm i @reventless/reventless-aws` inside your project directory.

### Core- & API-Stack

A [`Stack`](https://www.pulumi.com/docs/intro/concepts/stack/) is the actual deployment unit used by our infrastructure as code tool of choice [Pulumi](https://www.pulumi.com).  
The foundation of any platform built using Reventless is a Core-Stack. This is the central piece providing the necessary functionalities for `Plugins` to interact with each other.

## Create a new Plugin

A **Plugin** is a deployment unit in Reventless. It encapsulates a bounded context with its own components.

Reventless supports two approaches for building plugins:

1. **[Aggregate-Based Plugin](./aggregate-based-plugin.md)** - Uses the traditional Aggregate pattern with Command Handlers and Event Log
2. **[DCB-Based Plugin](./dcb-based-plugin.md)** - Uses Dynamic Consistency Boundaries with shared event log and optimistic concurrency

For an overview of both approaches and how to create a plugin, see the [Plugin System](./plugin-system.md) guide.

## Next Steps

- [AWS Get Started](/docs/aws/get-started) - Deploy your application to AWS
- [Writing Unit Tests](./writing-unit-tests.md) - Write tests for your Reventless application

## Reventless Components

Find an overview of the most important Reventless Components in [component-overview.md](./component-overview.md).
