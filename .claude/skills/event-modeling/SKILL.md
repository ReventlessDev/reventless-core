---
name: event-modeling
description: >-
  Event Modeling methodology for Reventless domain analysis.
  Use when translating Event Modeling diagrams or JSON into
  Reventless components, identifying bounded contexts, or
  discovering plugin boundaries and extension points.
---

## Purpose

Bridges Event Modeling methodology with Reventless implementation. Helps developers translate domain models (swimlane diagrams, slice definitions, Event Modeling JSON) into concrete Reventless components — plugins, aggregates, slices, read models, and extension points.

## When to Use

- User references Event Modeling methodology or provides EM diagrams
- User provides Event Modeling JSON (exported from tools like Eventmodeling.org or Qlerify)
- Analyzing a domain to identify bounded contexts and plugin boundaries
- Discovering which events should be exposed as extension points

## Relationship to Other Skills

- **This skill** handles the *analysis* phase: understanding the domain model
- **`reventless-app`** handles the *generation* phase: producing code from the analyzed model
- **`event-sourcing-cqrs`** explains the underlying ES/CQRS concepts

Typical flow: `event-modeling` → structured design → `reventless-app` → generated code

## Reference Files

| File | Content |
|------|---------|
| `references/methodology.md` | Core EM concepts, 4 patterns, swimlane structure |
| `references/pattern-mapping.md` | EM patterns → Reventless component mapping |
| `references/bounded-context-discovery.md` | Identifying plugins from event models |
| `references/extension-point-discovery.md` | Cross-boundary flows → extension points |

## Key Rules

1. **Each EM slice maps to exactly one Reventless component** — no multi-component slices
2. **Group slices by bounded context** — each context becomes a Reventless plugin
3. **Events crossing context boundaries** → extension points
4. **Automation slices** → AutomationSlice (DCB) or EventMapper (Aggregate)
5. **Translation slices** → InboundTranslation / OutboundTranslation (DCB)

## Related Skills

- `reventless-app` — generates code from analyzed domain model
- `event-sourcing-cqrs` — explains ES/CQRS concepts behind the patterns
