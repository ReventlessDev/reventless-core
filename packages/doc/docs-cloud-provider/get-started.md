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

Add a new directory under `packages/` in the monorepo:

```bash
mkdir packages/reventless-myprovider
cd packages/reventless-myprovider
```

## 2. Set Up rescript.json

```json
{
  "name": "reventless-myprovider",
  "version": "11.0.0",
  "sources": [
    {
      "dir": "src",
      "subdirs": true
    }
  ],
  "bs-dependencies": [
    "reventless-spec",
    "reventless",
    "rescript-myprovider-sdk"
  ],
  "ppx-flags": ["sury-ppx/bin"],
  "bsc-flags": ["-open RescriptCore"],
  "suffix": ".res.js"
}
```

## 3. Set Up package.json

```json
{
  "name": "@reventless/reventless-myprovider",
  "version": "0.0.1",
  "private": true,
  "scripts": {
    "build": "rescript build",
    "start": "rescript build -w",
    "rebuild": "rescript clean && rescript build",
    "test": "jest"
  },
  "dependencies": {
    "@reventless/reventless": "*",
    "@reventless/reventless-spec": "*"
  }
}
```

## 4. Implement Adapter Interfaces

For each component you want to support, implement the adapter interfaces defined in `reventless`. See the [Adapter Pattern](./adapter-pattern.md) for the full checklist.

Start with the core event sourcing adapters:

1. **EventLog storage** — append-only event log with optimistic concurrency
2. **CommandTopic channel** — message queue for commands
3. **EventTopic publisher** — pub/sub for events

## 5. Export Pre-Configured Builders

Expose builder modules that pre-wire the framework functors with your adapters:

```rescript
// MyProviderEventLog.res
module Make = (Spec: ReventlessSpec.EventLog.Spec) =>
  EventLog_Builder.Make(Spec, MyEventLogStorage, MyEventTopicPublisher)
```

This is the API surface that application developers use.

## 6. Reference the AWS Implementation

The `reventless-aws` package is the canonical reference implementation. When in doubt, examine how it implements a given adapter — the patterns apply directly to other providers.

```
packages/reventless-aws/src/adapter/
├── EventLog/
├── CommandTopic/
├── EventTopic/
├── QueryDb/
├── Task/
└── DcbEventLog/
```
