# Reventless Discovery Checklist

Run these checks before implementing any Reventless component. Scale to complexity level (L1 = items marked [L1+], L2 = all items).

## Naming Conventions

- [L1+] **Aggregates** use singular nouns: `Product`, `Order`, `Customer`
- [L1+] **Read models** use plural nouns: `Products`, `Orders`, `Customers`
- [L1+] **Commands** are imperative: `Add`, `UpdateName`, `PlaceOrder`
- [L1+] **Events** are past tense: `Added`, `NameUpdated`, `OrderPlaced`
- [L1+] **Extension points** use dotted names: `"Catalog.Products"`, `"Ordering.Orders"`
- [L1+] **StateChangeSlices** are named after the command: `AddProduct`, `ChangeProductName`
- [L1+] **StateViewSlices** are named after the view: `ProductsView`, `OrdersView`
- [L2] **Plugin namespaces** follow `<Plugin>Plugin` (e.g., `CatalogPlugin`)
- [L2] **Spec namespaces** follow `<Plugin>Spec` (e.g., `CatalogSpec`)

## Schema Annotations

- [L1+] All serializable types have `@schema` attribute: commands, events, errors, state
- [L1+] DCB entity ID fields have `@s.matches(DcbTag.string)` on the **type expression** (after the colon)
- [L1+] Both command AND event types have `@s.matches` on entity ID fields
- [L1+] `@s.matches` is NOT on the field name (silently ignored by PPX)

## Module URL

- [L1+] Spec files requiring dynamic import have `let moduleUrl: string = %raw(\`import.meta.url\`)`
- Applies to: Aggregate specs, StateChangeSlice specs, EP mapping modules, Extension mapping modules, SideEffect modules

## File Structure

- [L1+] Aggregate: `EntityName.res` (spec) + `EntityNameBehavior.res` (logic)
- [L1+] DCB: one file per command in `StateChangeSlice/`, one file per view in `StateViewSlice/`
- [L1+] ReadModel: `EntityReadModel.res` (spec) + `EntityProjections.res` (mappings)
- [L2] Plugin composition root: `PluginNamePlugin.res` with `Make` functor
- [L2] Spec package: separate package with `<Plugin>Spec` namespace

## Plugin Composition

- [L1+] New components are registered in the plugin composition root (`Plugin.make(...)`)
- [L1+] Aggregates go in `~aggregates=[...]`
- [L1+] ReadModels go in `~readModels=[...]`
- [L1+] StateChangeSlices go in `~stateChangeSlices=[...]`
- [L1+] StateViewSlices go in `~stateViewSlices=[...]`
- [L2] Extension points need EP mapping modules + builder
- [L2] Extensions need extension mapping modules + builder

## Package Configuration

- [L2] `package.json` has correct dependencies (sury, reventless packages, spec packages)
- [L2] `rescript.json` has correct namespace, bs-dependencies, sources
- [L2] `sury-ppx/bin` is in the PPX list
- [L2] `-open RescriptCore` is in bsc-flags

## Cross-Plugin Communication

- [L2] Extension point types live in a separate spec package
- [L2] Plugins never import directly from other plugins
- [L2] Extension point spec packages have minimal dependencies (sury, reventless-spec only)
- [L2] DCB extension points use a shim module exposing the event log as an `Aggregate.Spec`

## Build Verification

- [L1+] Run `npm run build` and check for zero warnings
- [L1+] Run `npm test` in the affected package
- [L2] After file reorganization: `npx rescript clean && npm run build` from root
- [L2] Verify `Component.js` in reventless-spec was not overwritten by rescript build

## Analogous Component Search

When adding a new component, find at least one similar existing component:

1. Search the same plugin for components of the same type
2. Search sibling plugins for the same pattern
3. Note: file naming, import structure, wiring pattern, test structure
4. Use the existing component as a template — match its patterns exactly

## Architecture Decision

- [L2] For new entities: evaluate against `docs/guides/aggregate-vs-dcb-decision-guide.md`
- [L2] Check if the entity needs cross-entity state at decision time → DCB
- [L2] Check if the entity has a self-contained lifecycle → Aggregate
- [L2] If the plugin already uses DCB, prefer DCB for cohesion
