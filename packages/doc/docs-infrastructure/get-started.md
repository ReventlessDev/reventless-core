---
title: Scaffolding a Provider Package
sidebar_position: 2
---

# Scaffolding a New Cloud Provider Package

This guide walks through creating a new `reventless-<provider>` package from scratch.

## Prerequisites

- Familiarity with the [Framework Developer Guide](/framework)
- Understanding of the [Adapter Pattern](./adapter-pattern.md)
- A Pulumi provider for your target cloud platform

## 1. Create the Package

Provider packages live under `reventless/` (the framework root), **not** `packages/`
(which is build tooling and docs only):

```bash
mkdir reventless/reventless-myprovider
cd reventless/reventless-myprovider
```

## 2. Set Up rescript.json

The `reventless-ppx` flag **must** come before `sury-ppx`, and the output suffix is
`.res.mjs`:

```json
{
  "name": "reventless-myprovider",
  "version": "1.0.0-alpha.0",
  "sources": [
    {
      "dir": "src",
      "subdirs": true
    }
  ],
  "ppx-flags": ["@reventlessdev/reventless-ppx/bin", "sury-ppx/bin"],
  "bsc-flags": ["-open RescriptCore"],
  "dependencies": [
    "@reventlessdev/reventless-spec",
    "@reventlessdev/reventless-core",
    "@reventlessdev/reventless-infra",
    "rescript-myprovider-sdk"
  ],
  "suffix": ".res.mjs"
}
```

## 3. Set Up package.json

```json
{
  "name": "@reventlessdev/reventless-myprovider",
  "version": "1.0.0-alpha.0",
  "private": true,
  "scripts": {
    "build": "rescript build",
    "start": "rescript watch",
    "rebuild": "pnpm run clean && pnpm run build",
    "clean": "rescript clean",
    "test": "jest"
  },
  "dependencies": {
    "@reventlessdev/reventless-core": "workspace:*",
    "@reventlessdev/reventless-spec": "workspace:*",
    "@reventlessdev/reventless-infra": "workspace:*"
  }
}
```

## 4. Implement Adapter Interfaces

For each component you want to support, implement the adapter interfaces defined in `reventless-core`. See the [Adapter Pattern](./adapter-pattern.md) for the full checklist.

Start with the core event sourcing adapters:

1. **EventLog storage** — append-only event log with optimistic concurrency
2. **CommandTopic channel** — message queue for commands
3. **EventTopic publisher** — pub/sub for events

## 5. Export Pre-Configured Builders

Expose builder modules that pre-wire the framework functors with your adapters:

```rescript
// MyProviderEventLog.res
module Make = (Spec: Reventless.EventLog.Spec) =>
  EventLog_Builder.Make(Spec, MyEventLogStorage, MyEventTopicPublisher)
```

This is the API surface that application developers use.

## 6. Reference the AWS Implementation

The `reventless-aws` package is the canonical reference implementation. When in doubt, examine how it implements a given adapter — the patterns apply directly to other providers.

```
reventless/reventless-aws/src/adapter/
├── EventLog/
├── CommandTopic/
├── EventTopic/
├── QueryDb/
├── Task/
└── DcbEventLog/
```
