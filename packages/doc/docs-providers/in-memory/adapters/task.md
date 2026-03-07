---
title: Task
sidebar_position: 6
---

# Task — InMemory

**Source:** `reventless-in-memory/src/adapter/Task/TaskBucket_InMemory.res`

**AWS equivalent:** [Task → S3](/providers/aws/adapters/task)

## How It Works

The `make` function returns a dummy resource (no actual storage bucket is created). The `connect` function is a no-op.

`makeHandler` wraps a `Task.bucketCallback` and extracts `eventName` and `key` fields from the incoming JSON, simulating S3 event notifications.

## Operations

| Operation | Description |
|-----------|-------------|
| `make` | Returns a dummy resource with the task name |
| `connect` | No-op (no Lambda-to-S3 wiring needed) |
| `makeHandler` | Extracts `eventName` and `key` from JSON, calls the callback |

## Key Differences from AWS

| Aspect | InMemory | AWS |
|--------|----------|-----|
| Storage | No actual storage | S3 bucket with CORS |
| Events | Manual JSON with `eventName`/`key` fields | S3 ObjectCreated/ObjectRemoved events |
| Lambda trigger | Direct function call | S3 → Lambda event subscription |
| IAM | None | Per-bucket read/write policies |
