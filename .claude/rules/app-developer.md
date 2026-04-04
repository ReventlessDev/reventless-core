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

- `@@reventless.spec` — on all spec files (aggregates, read models, extension points, slices). Auto-injects `let name`, `module Id`, `let moduleUrl`. Derives name from filename (strips component suffixes like `ReadModel`, `ExtensionPoint`, `Behavior`, etc.). In `*Spec` namespaces, auto-prefixes with plugin name for dotted EP names. For files whose name contains `ReadModel` and that declare `@schema type state` without a `let config`, also auto-injects `open Reventless.ReadModel; let config = config(); let subIdConfig = None`. For files whose name contains `ExtensionPointMapping`, also auto-injects `open ReventlessInfra.ExtensionPointMapping` (brings `PublishEvent`, `PublishCommand`, `PublishEventAsync`, `Call` into scope). In `@@reventless.spec`-annotated files, any `module Delegate` is auto-transformed (injects `module Id`, `@schema type command = unit`, dcbTags on `*Id` event fields, `@schema type error = unit`, `let moduleUrl`).
- `@@reventless.spec("ExplicitName")` — same, with explicit name override
- `@@reventless.behavior` — on all behavior files. Auto-injects `open Spec`, `module Spec = Spec`, `let moduleUrl`. Derives spec module from filename (strips `Behavior` suffix).
- `@@reventless.behavior(SpecName)` — same, with explicit spec module name
- `@@reventless.dcbTags` — explicit opt-in for files outside `*Slice/` folders. Files inside any `*Slice/` folder (StateChangeSlice, StateViewSlice, AutomationSlice, InboundTranslationSlice, OutboundTranslationSlice) get dcbTags automatically via `@@reventless.spec`. Auto-injects `@s.matches(Reventless.DcbTag.string)` on: `*Id: string` scalar fields; element types of `*Id: array<string>` fields (singular name, array type — for cross-entity queries where tag key must match stored event field name); element types of `*Ids: array<string>` fields (plural name — for multi-value storage). To suppress auto-tagging on a payload `*Id` field that is NOT a DCB query key, annotate the type expression: `customerId: @s.matches(S.string) string`.
- `@reventless.projections` — on projection module bindings inside plugin functor bodies. Auto-injects `module M = Reventless.Projection.Mappings.Make(Target)`, `module type Mapping = M.Mapping`, and `let moduleUrl`. Extracts Target from the `with module Target := X` constraint.
- `@reventless.delegate` — explicit opt-in for `Delegate`-like modules outside `*ExtensionPointMapping*` files. In `@@reventless.spec`-annotated `*ExtensionPointMapping*` files, the `Delegate` module is auto-transformed without this attribute.
- `@schema` on all serializable types (command, event, error, state)
- PPX ordering in `rescript.json`: `"ppx-flags": ["@reventlessdev/reventless-ppx/bin", "sury-ppx/bin"]` (reventless-ppx before sury-ppx)

## Idempotency

Commands that would produce no state change should return `Ok([])`, not an error. This is important because commands may be retried due to at-least-once delivery.

## Architecture Decision

Before adding a new entity, evaluate against `docs/guides/aggregate-vs-dcb-decision-guide.md`. Cross-entity consistency needs → DCB. Self-contained lifecycle → Aggregate.
