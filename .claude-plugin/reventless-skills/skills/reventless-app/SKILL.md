---
name: reventless-app
description: >-
  Generate complete Reventless applications from domain requirements.
  Use when creating new plugins, aggregates, read models, DCB slices,
  extension points, or entire platforms. Handles both Aggregate and
  DCB architectural styles.
---

## Purpose

Generates complete, compilable Reventless application code from domain requirements. Produces all necessary files — specs, behaviors, projections, slices, plugin composition, platform wiring, configuration, and tests.

## When to Use

- Creating a new Reventless platform from scratch
- Adding a new plugin (bounded context) to an existing platform
- Adding components (aggregates, slices, read models, extensions) to an existing plugin
- Converting between Aggregate and DCB approaches

## Workflow

### Phase 1 — Requirements Gathering

Ask the developer about:

1. **Bounded context:** What is the domain? (e.g., "Catalog", "Ordering")
2. **Entities:** What are the main entities? (e.g., "Product", "Order")
3. **Commands/Events:** For each entity — what actions can users perform? What facts are recorded? What can go wrong?
4. **Queries:** What views do users need? What fields should be queryable?
5. **Cross-plugin:** Does this plugin publish events for others? Subscribe to events from others?
6. **Side effects:** Email notifications, external API calls, data imports, automated workflows?

### Phase 2 — Architecture Design

Evaluate each entity against `docs/guides/aggregate-vs-dcb-decision-guide.md`:

- Cross-entity state checks needed? → DCB
- Self-contained lifecycle? → Aggregate
- Synced from external plugin? → DCB
- Automation/translation needed? → DCB
- None of the above? → Aggregate

Produce a design summary for confirmation before generating code.

### Phase 3 — Code Generation

Generate files in dependency-safe order:

1. Spec package (if extension points exist)
2. Plugin package configuration (package.json, rescript.json)
3. Domain types (Aggregate specs or StateChangeSlice files)
4. Business logic (Behaviors or slice decide functions)
5. Read-side projections (ReadModel + Projections or StateViewSlices)
6. Cross-plugin communication (EP specs, EP mappings, Extensions)
7. Side effects and automation (if needed)
8. Plugin composition root
9. Platform composition root (if new platform)
10. Tests
11. Run `npm install` and `npm run build` to verify

## Reference Files

| File | Content |
|------|---------|
| `references/component-catalog.md` | All component types with specs, builders, key fields |
| `references/aggregate-patterns.md` | Complete code templates for aggregate architecture |
| `references/dcb-patterns.md` | Complete code templates for DCB architecture |
| `references/querydb-key-patterns.md` | QueryDb key annotations: `@id`, `@subId`, `@index`, `@resolves`, sort key query args |
| `references/cross-plugin-patterns.md` | ExtensionPoint specs, EP mappings, Extension mappings |
| `references/configuration-templates.md` | package.json and rescript.json templates |
| `references/testing-patterns.md` | Test file templates for all component types |

## Key Rules

1. **Always read the decision guide** at `docs/guides/aggregate-vs-dcb-decision-guide.md` before choosing architecture
2. **Always read the platform-and-plugin guide** at `docs/guides/platform-and-plugin-guide.md` for composition patterns
3. **Every serializable type needs `@schema`** — commands, events, errors, state
4. **DCB entity IDs need `@s.matches(DcbTag.string)`** on the type expression
5. **Every spec file needs `let moduleUrl`** — `let moduleUrl: string = %raw(\`import.meta.url\`)`
6. **Naming conventions:** Aggregates = singular (Product), ReadModels = plural (Products), Commands = imperative (Add), Events = past tense (Added)
7. **Source file organisation:** Each component type in its own subdirectory. No `Spec`, `View`, or `Slice` suffixes — the directory conveys the type:
   - `src/StateChange/` — StateChangeSlices (e.g. `SyncPlugin.res`, not `SyncPluginSpec.res`)
   - `src/StateView/` — StateViewSlices (e.g. `ResourceInventory.res`, not `ResourceInventoryView.res`)
   - `src/ReadModel/` — ReadModels and Projections (CQRS-style, distinct from StateView)
   - `src/Aggregate/` — Aggregates and their Behaviors (co-located, not separate folders)
   - `src/InboundTranslation/` — InboundTranslationSlices
   - `src/OutboundTranslation/` — OutboundTranslationSlices
   - `src/Automation/` — AutomationSlices
   - `src/ExtensionPoint/` — ExtensionPoint specs
   - `src/Types/` — shared type modules
7. **Idempotency:** Return `Ok([])` for no-change commands, not an error
8. **Spec packages** for extension points — never import directly from another plugin

## Related Skills

- `rescript` — ReScript v12 patterns used in generated code
- `event-sourcing-cqrs` — conceptual foundations for architecture decisions
- `event-modeling` — Event Modeling methodology for domain analysis
- `reventless-testing` — test patterns for generated test files
- `reventless-context` — pre-implementation discovery for existing projects
