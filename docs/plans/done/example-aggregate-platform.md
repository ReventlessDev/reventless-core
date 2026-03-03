# Plan: Add `example-aggregate` Package — In-Memory Platform for Aggregate Plugins

**Status: DONE**

## Goal

Create a new package `examples/aggregate/example-aggregate/` that runs the two existing aggregate bounded contexts (Catalog and Ordering) on an in-memory platform. Mirror the same self-assembly pattern already established in the DCB example (`examples/dcb/example-dcb/`).

## Design Principle

**Plugins own their composition; the platform package owns the provider choice.**

- Each plugin's `Make` functor receives a `Platform: ReventlessInfra.Platform.T` and calls `Platform.Plugin.make` internally, producing a ready-to-use `Plugin.component`.
- The platform package (`example-aggregate`) picks the in-memory provider, creates a scheduler, passes it to each plugin, and calls `makePlatform`.
- Switching from in-memory to AWS (or any other provider) only requires changing the platform package — the plugins are untouched.

## What Was Done

### 1. Extended `CatalogPlugin.Make` with self-assembly

File: `examples/aggregate/catalog/src/CatalogPlugin.res`

Added a `make` function that calls `Platform.Plugin.make` with `~aggregates` (ProductAggregate, CategoryAggregate, ProductDemandAggregate), `~readModels` (ProductReadModel, CategoryReadModel, ProductDemandReadModelMaker), `~extensionPoints`, and `~extensions`. Replaced the old commented-out `// extensionPoints = [...]` lines.

### 2. Extended `OrderingPlugin.Make` with self-assembly

File: `examples/aggregate/ordering/src/OrderingPlugin.res`

Same pattern as Catalog — added `make` function with `~aggregates` (CustomerAggregate, OrderAggregate, CatalogProductAggregate) and `~readModels` (CustomerReadModel, OrderReadModel, AvailableProductsReadModelMaker).

### 3. Added `rescript-pulumi-pulumi` dependency to plugin packages

Files: `examples/aggregate/catalog/rescript.json`, `examples/aggregate/ordering/rescript.json`

The `make` function signature references `Pulumi.Output.t`, which requires `@reventlessdev/rescript-pulumi-pulumi` as a ReScript dependency. Added it to both plugin packages (matching the DCB plugin configuration).

### 4. Created `example-aggregate` package

Files created:
- `examples/aggregate/example-aggregate/package.json`
- `examples/aggregate/example-aggregate/rescript.json`
- `examples/aggregate/example-aggregate/src/Main.res`

### 5. Added package to root `rescript.json` dependencies

## Namespace Note

ReScript auto-derives namespace from `@reventlessdev/example-aggregate-catalog` → `ReventlessdevExampleAggregateCatalog`. Main.res must use the full namespace: `ReventlessdevExampleAggregateCatalog.CatalogPlugin.Make(Platform)`.

## Running

```bash
cd examples/aggregate/example-aggregate
npx tsx src/Main.res.mjs
```

The `tsx` runner is required because ReScript ESM output imports hand-written `.js` files without extensions, which bare `node` can't resolve. `tsx` handles this automatically.

Output: GraphQL server on `http://localhost:4000/graphql`

## Test Results

All existing tests pass after the changes:
- Catalog: 26 tests passed (6 suites)
- Ordering: 30 tests passed (6 suites)
- Build: zero warnings

## Key Difference from DCB Plan

The aggregate plugins pass `~aggregates` and `~readModels` arrays to `Platform.Plugin.make` instead of `~dcbSpec`. The `Plugin.make` signature accepts both patterns — they're all optional parameters. No `DcbSpec` module is needed for aggregate plugins.
