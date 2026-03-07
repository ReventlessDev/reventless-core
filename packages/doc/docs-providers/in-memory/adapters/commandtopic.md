---
title: CommandTopic
sidebar_position: 2
---

# CommandTopic — InMemory

**Source:** `reventless-in-memory/src/adapter/CommandTopic/CommandTopicChannel_InMemory.res`

**AWS equivalent:** [CommandTopic → SQS FIFO](/providers/aws/adapters/commandtopic)

## How It Works

Commands are dispatched directly via the shared `InMemory_Bus`. There is no queue — `publishJsons` encodes each command as `{id, meta, command}` and calls `Bus.dispatchCommand`, which looks up the registered handler and invokes it synchronously.

The `connect` function registers the aggregate's command handler on the bus using the channel name as the key.

## Operations

| Operation | Description |
|-----------|-------------|
| `publishJsons` | Encodes commands and dispatches via `Bus.dispatchCommand` |
| `publishJsonsStream` | Stream variant — groups items into batches of 10 |
| `handleChannelEvent` | Wraps the command handler for the runtime |
| `connect` | Registers the handler on the bus for this channel name |

## Key Differences from AWS

| Aspect | InMemory | AWS |
|--------|----------|-----|
| Transport | Direct function call via bus | SQS FIFO queue |
| Ordering | Guaranteed (single-threaded) | Per-message-group FIFO ordering |
| Deduplication | None needed | Content-based deduplication |
| Dead letter queue | None | Configurable DLQ |
| Visibility timeout | N/A | 180 seconds |
