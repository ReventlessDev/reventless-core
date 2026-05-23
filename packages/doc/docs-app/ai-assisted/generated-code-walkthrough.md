---
title: Generated Code Walkthrough
sidebar_position: 5
---

# Generated Code Walkthrough

When you ask the AI to create a Reventless application, it generates a complete set of files. Here's what each file does.

## DCB Architecture (Example: Catalog Plugin)

```
catalog-spec/                          # Extension point types
├── package.json
├── rescript.json
└── src/
    └── Products_ExtensionPoint.res    # Public event API

catalog/                               # Plugin implementation
├── package.json
├── rescript.json
├── __mocks__/emptyModule.js
└── src/
    ├── Product/
    │   ├── StateChangeSlice/
    │   │   ├── AddProduct.res             # Command spec: add a product
    │   │   ├── AddProduct_Behavior.res    # state / evolve / decide
    │   │   ├── ChangeProductName.res      # Command spec: rename
    │   │   ├── ChangeProductName_Behavior.res
    │   │   ├── ChangeProductPrice.res     # Command spec: reprice
    │   │   └── ChangeProductPrice_Behavior.res
    │   └── StateViewSlice/
    │       ├── Products.res               # Query spec: product listings
    │       └── Products_Projection.res    # project function
    ├── ExtensionPoint/
    │   └── Products_ExtensionPointMapping.res  # Internal → public events
    ├── Extension/
    │   └── Orders_Extension.res           # Subscribe to Ordering events
    └── Plugin.res                         # GENERATED — wires everything

platform-in-memory/                    # Platform assembly
├── package.json
├── rescript.json
└── src/
    └── Main.res                       # Starts the platform
```

Each component is **split** into a spec file (`@@reventless.spec` — types only)
and a body file (`_Behavior.res`, `_Projection.res`, `_Translation.res`, or
`_Automation.res` — logic only). `Plugin.res` is **generated** by
`generate-plugin` from the folder layout and carries an "AUTO-GENERATED — do
not edit" banner.

## Key Files Explained

### StateChangeSlice (e.g., `AddProduct.res` + `AddProduct_Behavior.res`)

Handles one command type, split across two files.

The **spec** (`AddProduct.res`, `@@reventless.spec`) declares:
- **consumedEvent** — events this slice reads from the shared log to build decision state
- **command** — the command this slice handles
- **error** — the business errors it can return
- **event** — the events it produces on success

The **behavior** (`AddProduct_Behavior.res`, `@@reventless.behavior`) declares:
- **state** — minimal decision state (what's needed to accept/reject)
- **initialState** — the starting value before any event is replayed
- **evolve** — builds decision state from consumed events
- **decide** — business rule: accept or reject the command

### StateViewSlice (e.g., `Products.res` + `Products_Projection.res`)

Projects events into a queryable read model, split across two files.

The **spec** (`Products.res`, `@@reventless.spec`) declares:
- **state** — the shape of the view record
- **consumedEvent** — events this view cares about

The **projection** (`Products_Projection.res`, `@@reventless.projection`) declares:
- **project** — maps each event to Set/Update/UpdateWithDefault/Delete operations

### Plugin Composition (`Plugin.res` — generated)

The wiring file is **generated** from the folder layout — do not hand-edit it:
1. Builds each slice/view via `Platform.StateChangeSlice.Make(Spec, Behavior)` / `Platform.StateViewSlice.Make(Spec, Projection)` (two args: spec + body)
2. Wires extension point mappings and extensions
3. Assembles everything into `Platform.Plugin.make(...)` with named arrays

### Platform Main (e.g., `Main.res`)

A few lines that start everything:
1. Create the platform: `module Platform = ReventlessInMemory.Platform.Make()`
2. Build each plugin: `module Catalog = CatalogPlugin.Plugin.Make(Platform)` (note the `.Plugin.` segment)
3. Start: `Platform.makePlatform(~version=..., ~plugins=[...])`

## Configuration Files

### `package.json`

Dependencies on Reventless framework packages, spec packages from other plugins, and Jest configuration for testing.

### `rescript.json`

ReScript compiler config with namespace, PPX flags, and dependency ordering. The namespace (`CatalogPlugin`) combines with the generated `Plugin` module to give the path `CatalogPlugin.Plugin.Make(Platform)`.

## What You Can Modify

All component code is regular ReScript — modify freely:
- Add fields to commands/events
- Add new guard conditions in `decide`
- Change projection logic in `project`
- Add new slices or read models (drop a new spec + body into the right folder)

The one exception is `Plugin.res` — it is generated from the folder layout, so
re-run `generate-plugin` (or `pnpm run build`, whose `prebuild` step does it for
you) after adding or renaming components rather than editing the wiring by hand.

After modifications, run `pnpm run build` to verify everything compiles, then `pnpm test` to run tests.
