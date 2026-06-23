---
slug: aggregate-vs-dcb
title: "Aggregate vs DCB: when to use which"
authors: [reventless]
tags: [dcb, event-sourcing]
date: 2026-05-22
draft: true
---

One of the first modelling decisions in Reventless is whether an entity should be
an **aggregate** (one event log per instance) or a **DCB slice** (a shared,
tag-filtered log with per-command optimistic concurrency). The short answer: it
depends on whether the entity needs to reason about *other* entities.

<!-- truncate -->

## The rule of thumb

For each entity, ask:

1. Does its decision need to see other entities' events? → **DCB**.
2. Does a read model need to combine its events with another entity's events? →
   both entities should share a **DCB** log.
3. Is its lifecycle fully independent? → **Aggregate**.

If every entity points the same way, use that pure style. If the answers are
mixed — which is common in real systems — use a **hybrid** plugin and model each
entity with the approach that fits it.

## Two consistency models

- **Aggregates** give you a sequential consistency boundary per instance: each
  command replays that instance's stream, decides, and appends. Simple and
  isolated.
- **DCB** (Dynamic Consistency Boundary) gives you optimistic concurrency per
  command across a shared log: a slice reads exactly the tagged events it needs to
  decide — including events from other entities — and appends if nothing changed
  underneath it. This is what lets `PlaceOrder` validate that referenced products
  exist without a cross-aggregate query.

## Go deeper

- The full [decision guide](/app/aggregate-vs-dcb-decision-guide) in the App Guide.
- [Choosing an approach](/tutorials/choosing-an-approach) in the tutorial, which
  applies the rule to the online-shop example.
