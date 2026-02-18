---
title: Cloud Provider Guide
sidebar_position: 1
---

# Cloud Provider Package Guide

This guide is for authors of cloud provider adapter packages — packages like `reventless-aws` that implement the framework's adapter interfaces for a specific cloud platform.

If you are building an application, see the [App Developer Guide](/app). If you are contributing to the framework core, see the [Framework Developer Guide](/framework).

## What a Cloud Provider Package Is

The `reventless` framework core defines components and their adapter interfaces but contains no infrastructure code. A cloud provider package:

1. **Implements adapter interfaces** — provides concrete implementations of `EventLog_Adapter.Storage`, `CommandTopic_Adapter.Channel`, `EventTopic_Adapter.Publisher`, etc.
2. **Provides pre-configured builders** — exports `Make` functors that wire the framework builder with the cloud-specific adapters, so application developers don't need to assemble them manually
3. **Manages deploy-time resources** — creates the actual cloud resources (queues, topics, tables, functions) using Pulumi

## The Two-Layer Model

Cloud provider packages implement two layers:

### Layer 1: Deploy-Time Adapters

These create cloud resources and return `Pulumi.Output.t`-wrapped ARNs, URLs, and configurations. For example, the AWS EventLog storage adapter creates a DynamoDB table and returns the table ARN.

### Layer 2: Runtime Adapters

These implement the actual data access logic at Lambda execution time — reading from DynamoDB, publishing to SQS, etc. They consume the `Pulumi.Output.t` values captured in the Lambda bundle during deploy time.

## Package Structure

A typical provider package follows this structure:

```
packages/reventless-<provider>/
├── src/
│   └── adapter/
│       ├── EventLog/
│       │   ├── EventLog_StorageAdapter.res   # deploy-time: creates the table
│       │   └── EventLog_StorageRuntime.res   # runtime: reads/writes
│       ├── CommandTopic/
│       │   ├── CommandTopic_ChannelAdapter.res
│       │   └── CommandTopic_ChannelRuntime.res
│       └── ...
├── rescript.json
└── package.json
```

## Existing Implementation

See `packages/reventless-aws/` for the complete AWS implementation. It implements adapters for:

- **EventLog** → DynamoDB (append-only log with optimistic concurrency)
- **CommandTopic** → SQS FIFO queue
- **EventTopic** → SNS topic
- **QueryDb** → DynamoDB (key-value store for read models)
- **Task** → S3 (binary object storage)
- **DcbEventLog** → DynamoDB (shared event log with tag-based querying)

The AWS package is the reference implementation for any new provider package.

## Get Started

See [Get Started](./get-started.md) to scaffold a new provider package and [Adapter Pattern](./adapter-pattern.md) for the full interface checklist.
