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
- User provides Event Modeling JSON (exported from tools like the Nebulit Miro toolkit, eventmodelers.ai or Qlerify)
- Analyzing a domain to identify bounded contexts and plugin boundaries
- Discovering which events should be exposed as extension points

## Event Modeling JSON: run the importer, don't translate by hand

When the user has an Event Modeling JSON file, the `reventless-codegen` tooling turns it into code. It lives outside reventless-core.

- **VS Code:** *Reventless: Generate from Event Model…* imports, *Export to Event Model…* writes the plugin back out, and *Check Model Drift…* compares the two.
- **CLI:** `forward` (import), `validate`, `export` and `watch`, all with `--adapter eventmodeling`. See `docs/guides/forward-codegen-pipeline.md` and `docs/guides/reverse-codegen-pipeline.md` in reventless-core.

Per slice, `forward` writes the Spec file and the GWT file (regenerated while they carry the generated header). It writes a behaviour skeleton only if none exists, and the plugin's `package.json` / `rescript.json` / `plugin.json` only if absent. A slice's `context` becomes plugin + chapter folder. `specifications[]` become GWT scenarios with typed example values. Screens, actors, status and timeline order are carried through to export unchanged, but nothing interprets them.

Check whether the user can run the importer before writing any of those files by hand. If they can't, use the mapping in `references/` and emit the same layout. Either way, this skill's job is the analysis the importer cannot do:

- decide bounded contexts when the JSON has no `context` fields (`references/bounded-context-discovery.md`);
- find extension points among cross-context flows (`references/extension-point-discovery.md`);
- choose Aggregate or DCB per entity: the importer emits DCB slices, and a self-contained entity may be better as an aggregate;
- hand the skeletons to `reventless-app` to fill in `evolve` / `decide` / `project` against the scenarios.

## Relationship to Other Skills

- **This skill** handles the *analysis* phase: understanding the domain model
- **`reventless-app`** handles the *generation* phase: producing code from the analyzed model
- **`event-sourcing-cqrs`** explains the underlying ES/CQRS concepts

Typical flow: `event-modeling` (+ importer for JSON) → structured design → `reventless-app` → generated code

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
4. **Automation slices** → AutomationSlice (fed by DCB or Aggregate events), or EventMapper for stateless aggregate-to-aggregate routing
5. **Translation slices** → InboundTranslationSlice / OutboundTranslationSlice. Both work with aggregates too: an outbound slice can listen to an Aggregate (`sourceNames`), and either one can send its command to an Aggregate (`targetName`)
6. **Needing automation or translation is not a reason to choose DCB** — choose per entity on its consistency boundary (see the Aggregate vs DCB decision guide)

## Related Skills

- `reventless-app` — generates code from analyzed domain model
- `event-sourcing-cqrs` — explains ES/CQRS concepts behind the patterns
