---
title: Get Started
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

### Install Node and pnpm

- install [Node.js 22.17.1](https://nodejs.org/) (see `.node-version`)
- enable [pnpm](https://pnpm.io) 10 via Corepack: `corepack enable && corepack prepare pnpm@10 --activate`

### Initialize a new Project

Run `pnpm init` in the directory you want to create the new project in.

Add build scripts to your `package.json`:

```json
{
  "scripts": {
    "generate": "generate-plugin src/",
    "prebuild": "pnpm run generate",
    "build": "rescript build",
    "clean": "rescript clean",
    "start": "rescript watch"
  }
}
```

`generate-plugin` (shipped with `@reventlessdev/reventless-spec`) scans `src/` and writes the
composition root `src/Plugin.res` before each build. See the [Plugin System](./plugin-system.md)
guide for what it wires.

### Install Dependencies

Add the Reventless packages, the ReScript compiler, and Sury to your project. Packages are
published under the `@reventlessdev` scope on the GitHub Package Registry:

```bash
pnpm add @reventlessdev/reventless-spec @reventlessdev/reventless-infra sury
pnpm add -D @reventlessdev/reventless-ppx @reventlessdev/reventless-gwt rescript sury-ppx
```

Then add a provider package (see [Choose a Provider](#choose-a-provider) below) — e.g.
`@reventlessdev/reventless-local` for local development.

### Configure ReScript

Create a `rescript.json` in your project root. The `reventless-ppx` **must** come before
`sury-ppx`, and the output suffix is `.res.mjs`:

```json
{
  "name": "my-plugin",
  "namespace": "MyPlugin",
  "ppx-flags": ["@reventlessdev/reventless-ppx/bin", "sury-ppx/bin"],
  "sources": [{ "dir": "src", "subdirs": true }],
  "dependencies": [
    "sury",
    "@reventlessdev/reventless-spec",
    "@reventlessdev/reventless-infra",
    "@reventlessdev/reventless-local"
  ],
  "suffix": ".res.mjs"
}
```

The PPX auto-injects boilerplate (`let name`, DCB tag annotations, and more) so you can focus on domain logic. See [PPX annotations](./rescript-syntax.md#reventless-ppx-annotations) for details.

### Choose a Provider

Reventless is provider-agnostic: a separate package per provider supplies the pre-configured
components and adapters. Packages are named `@reventlessdev/reventless-<provider>`:

- `@reventlessdev/reventless-local` — in-memory / SQLite backend for development and testing
- `@reventlessdev/reventless-aws` — AWS (DynamoDB, Lambda, SQS, SNS, S3)

> AWS and local providers ship today; more cloud targets are planned.

Install the one you need, e.g. `pnpm add @reventlessdev/reventless-aws`.

### The Platform

A **Platform** is the foundation every Reventless system is built on: it provides the shared
infrastructure (event routing, command channels, the admin plugin) that lets `Plugin`s interact
with each other. You select a Platform by choosing a provider — `ReventlessLocal.Platform` for
local runs, `ReventlessAws.Platform` for AWS — and each `Plugin` is a functor
`Make(Platform: ReventlessInfra.Platform.T)`. See the [Plugin System](./plugin-system.md) guide.

## Create a new Plugin

A **Plugin** is a deployment unit in Reventless. It encapsulates a bounded context with its own components.

A plugin can mix two building-block patterns:

1. **[Aggregates](./aggregates.md)** - Each entity has its own event log and sequential command processing
2. **[DCB Slices](./dcb-slices.md)** - Shared event log with optimistic concurrency across entities

For an overview of plugins, patterns, and cross-plugin communication, see the [Plugin System](./plugin-system.md) guide.

## Next Steps

- [AWS Get Started](/infrastructure/aws/get-started) - Deploy your application to AWS
- [Writing Unit Tests](./writing-unit-tests.md) - Write tests for your Reventless application

## Reventless Components

Find an overview of the most important Reventless Components in [component-overview.md](./component-overview.md).
