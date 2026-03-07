---
title: EventTopic
sidebar_position: 3
---

# EventTopic — InMemory

**Source:** `reventless-in-memory/src/adapter/EventTopic/EventTopicPublisher_InMemory.res`

**AWS equivalent:** [EventTopic → SNS](/providers/aws/adapters/eventtopic)

## How It Works

Events are published to the shared `InMemory_Bus` using `Bus.publishEvent`. The bus fans out events to all subscribers using Effect's `PubSub` primitive. The topic name (set during `make`) is used as the bus topic key.

The adapter returns a dummy resource with the topic name, which `EventCollectorChannel_InMemory` uses to subscribe to the correct bus topic.

## Operations

| Operation | Description |
|-----------|-------------|
| `publishJson` | Publishes a single event to the bus topic |
| `publishJsonStream` | Stream variant — groups items into batches of 10 |

## Key Differences from AWS

| Aspect | InMemory | AWS |
|--------|----------|-----|
| Transport | Effect PubSub fan-out | SNS topic |
| Delivery | Synchronous (2-3 microtask ticks) | Asynchronous SNS → SQS |
| Subscribers | Bus subscribers | SNS subscriptions (SQS, Lambda, etc.) |
| Fan-out | Unbounded or bounded PubSub | SNS unlimited subscriptions |
