---
name: event-sourcing-cqrs
description: >-
  Event Sourcing and CQRS fundamentals for Reventless developers.
  Use when discussing ES/CQRS concepts, designing domain models,
  making architecture decisions, or understanding why Reventless
  components work the way they do.
---

## Purpose

Explains Event Sourcing (ES) and Command Query Responsibility Segregation (CQRS) concepts in the context of Reventless. Bridges the gap between "I want to build an app" and understanding the architectural principles behind the framework.

This skill teaches concepts, not code. For code generation, use the `reventless-app` skill. For architecture decisions (Aggregate vs DCB), read `docs/guides/aggregate-vs-dcb-decision-guide.md`.

## When to Use

- Developer is new to ES/CQRS and asks conceptual questions
- Explaining *why* a Reventless component exists or works a certain way
- Discussing trade-offs between architectural approaches
- Helping a developer understand eventual consistency, projections, or event schema evolution
- When `reventless-app` needs to explain decisions during code generation

## Reference Files

| File | Content |
|------|---------|
| `references/event-sourcing-core.md` | Events as facts, append-only logs, replay, immutability |
| `references/cqrs-patterns.md` | Command/query separation, projections, eventual consistency |
| `references/consistency-boundaries.md` | Aggregates, DCB, optimistic concurrency |
| `references/cross-cutting-patterns.md` | Extension points, side effects, automation, translation |
| `references/reventless-concept-map.md` | ES/CQRS concept to Reventless component mapping |

## Key Analogies

When explaining to developers unfamiliar with ES/CQRS:

- **Event log** = "A database table where every row is a fact that happened, and you never UPDATE or DELETE — only INSERT."
- **Aggregate** = "A database row that remembers every change ever made to it. Instead of UPDATE, you append a fact. Instead of SELECT, you replay facts to rebuild current state."
- **Projection** = "A materialized view that updates itself whenever new events appear."
- **Command** = "A request to do something — it might be accepted or rejected."
- **Event** = "A fact that something happened — it's always true, never rejected."
- **Read model** = "A query-optimized view of data, separate from where the data is written."

## Related Skills

- `reventless-app` — generates code based on these concepts
- `event-modeling` — Event Modeling methodology for domain analysis
- `reventless-testing` — testing patterns for ES/CQRS components
