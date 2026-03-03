# Plan: Add `example-dcb` Package — In-Memory Platform for DCB Plugins

**Status: DONE**

## Goal

Create a new package `examples/dcb/example-dcb/` that runs the two existing DCB bounded contexts (Catalog and Ordering) on an in-memory platform. Each plugin package defines its own assembly — the platform package only chooses the provider and wires the plugins together.

## Design Principle

**Plugins own their composition; the platform package owns the provider choice.**

- Each plugin's `Make` functor receives a `Platform: ReventlessInfra.Platform.T` and calls `Platform.Plugin.make` internally, producing a ready-to-use `Plugin.component`.
- The platform package (`example-dcb`) picks the in-memory provider, creates a scheduler, passes it to each plugin, and calls `makePlatform`.
- Switching from in-memory to AWS (or any other provider) only requires changing the platform package — the plugins are untouched.

## What Was Done

### 1. Extended `CatalogPlugin.Make` with self-assembly

File: `examples/dcb/catalog/src/Plugin/CatalogPlugin.res`

Added a `DcbSpec` module (with `@schema type event`, `stateChangeSlices`, `stateViewSlices`) and a `make` function that calls `Platform.Plugin.make` with all the plugin's components. Replaced the old `module DcbSpec = CatalogEventLog` alias.

### 2. Extended `OrderingPlugin.Make` with self-assembly

File: `examples/dcb/ordering/src/Plugin/OrderingPlugin.res`

Same pattern as Catalog — added `DcbSpec` module and `make` function.

### 3. Created `example-dcb` package

Files created:
- `examples/dcb/example-dcb/package.json`
- `examples/dcb/example-dcb/rescript.json`
- `examples/dcb/example-dcb/src/Main.res`

### 4. Added package to root `rescript.json` dependencies

### 5. Fixed pre-existing `Plugin_Helpers` crash in in-memory mode

File: `reventless/reventless-core/src/components/Plugin/Plugin_Helpers.res`

Fixed 5 `Array.getUnsafe(0)` accesses that crash when `resources` array is empty (which is the case for in-memory mode since there are no Lambda/SQS/DynamoDB resources). Changed to safe `Array.get(0)` with fallback.

## Namespace Note

ReScript auto-derives namespace from `@reventlessdev/example-dcb-catalog` → `ReventlessdevExampleDcbCatalog`. Main.res must use the full namespace: `ReventlessdevExampleDcbCatalog.CatalogPlugin.Make(Platform)`.

## Running

```bash
cd examples/dcb/example-dcb
npx tsx src/Main.res.mjs
```

The `tsx` runner is required because ReScript ESM output imports hand-written `.js` files without extensions, which bare `node` can't resolve. `tsx` handles this automatically.

Output: `[GraphQL] Listening on http://localhost:4000/graphql`

## Test Results

All existing tests pass after the changes:
- Catalog: 44 tests passed
- Ordering: 48 tests passed
- In-memory adapters: 181 tests passed
