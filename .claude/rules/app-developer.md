# App Developer Guidelines

## Plugin Isolation

- Never import directly from another plugin's source code
- Use **spec packages** for extension point type definitions
- Cross-plugin communication flows through ExtensionPoint and Extension components only

## Naming Conventions

- **Aggregates:** singular nouns (Product, Order, Customer)
- **Read models / views:** plural nouns (Products, Orders, Customers)
- **Commands:** imperative (Add, UpdateName, PlaceOrder)
- **Events:** past tense (Added, NameUpdated, OrderPlaced)
- **Extension points:** dotted names ("Catalog.Products", "Ordering.Orders")
- **Plugin namespaces:** `{Plugin}Plugin` (CatalogPlugin)
- **Spec namespaces:** `{Plugin}Spec` (CatalogSpec)

## PPX Annotations

- `@@reventless.spec` — on all spec files (aggregates, read models, extension points, slices). Auto-injects `let name`, `module Id`, `let moduleUrl`. Derives name from filename (strips component suffixes like `ReadModel`, `ExtensionPoint`, `Behavior`, etc.). In `*Spec` namespaces, auto-prefixes with plugin name for dotted EP names.
- `@@reventless.spec("ExplicitName")` — same, with explicit name override
- `@@reventless.behavior` — on all behavior files. Auto-injects `open Spec`, `module Spec = Spec`, `let moduleUrl`. Derives spec module from filename (strips `Behavior` suffix).
- `@@reventless.behavior(SpecName)` — same, with explicit spec module name
- `@@reventless.dcbTags` — on DCB slice files. Auto-injects `@s.matches(Reventless.DcbTag.string)` on all `*Id: string` fields in `@schema` types.
- `@schema` on all serializable types (command, event, error, state)
- PPX ordering in `rescript.json`: `"ppx-flags": ["@reventlessdev/reventless-ppx/bin", "sury-ppx/bin"]` (reventless-ppx before sury-ppx)

## Idempotency

Commands that would produce no state change should return `Ok([])`, not an error. This is important because commands may be retried due to at-least-once delivery.

## Architecture Decision

Before adding a new entity, evaluate against `docs/guides/aggregate-vs-dcb-decision-guide.md`. Cross-entity consistency needs → DCB. Self-contained lifecycle → Aggregate.
