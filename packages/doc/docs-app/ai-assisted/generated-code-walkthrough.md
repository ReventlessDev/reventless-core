---
title: Generated Code Walkthrough
sidebar_position: 5
---

# What Gets Generated

When you ask the AI to create a Reventless application, it generates a complete set of files. Here's what each file does.

## DCB Architecture (Example: Catalog Plugin)

```
catalog-spec/                       # Extension point types
├── package.json
├── rescript.json
└── src/
    └── ProductsExtensionPoint.res  # Public event API

catalog/                            # Plugin implementation
├── package.json
├── rescript.json
├── __mocks__/emptyModule.js
└── src/
    ├── Product/
    │   ├── StateChangeSlice/
    │   │   ├── AddProduct.res       # Command: add a product
    │   │   ├── ChangeProductName.res # Command: rename
    │   │   └── ChangeProductPrice.res # Command: reprice
    │   └── StateViewSlice/
    │       └── ProductsView.res     # Query: product listings
    ├── ExtensionPoint/
    │   └── ProductsExtensionPointMapping.res  # Internal → public events
    ├── Extension/
    │   └── OrdersExtension.res      # Subscribe to Ordering events
    └── Plugin/
        └── CatalogPlugin.res        # Wires everything together

online-shop/                        # Platform root
├── package.json
├── rescript.json
└── src/
    └── Main.res                    # Starts the platform
```

## Key Files Explained

### StateChangeSlice (e.g., `AddProduct.res`)

Handles one command type. Contains:
- **state** — minimal decision state (what's needed to accept/reject)
- **consumedEvent** — events this slice reads from the shared log
- **evolve** — builds decision state from events
- **command** — the command this slice handles
- **producedEvent** — events produced on success
- **decide** — business rule: accept or reject the command

### StateViewSlice (e.g., `ProductsView.res`)

Projects events into a queryable read model. Contains:
- **state** — the shape of the view record
- **consumedEvent** — events this view cares about
- **project** — maps each event to Set/Update/Delete/Ignore operations

### Plugin Composition (e.g., `CatalogPlugin.res`)

The wiring file that connects all components:
1. Builds each slice/view via `Platform.StateChangeSlice.Make(...)` / `Platform.StateViewSlice.Make(...)`
2. Wires extension point mappings and extensions
3. Assembles everything into `Platform.Plugin.make(...)` with named arrays

### Platform Main (e.g., `Main.res`)

Three lines that start everything:
1. Create the platform: `module Platform = ReventlessInMemory.Platform.Make()`
2. Build each plugin: `module Catalog = CatalogPlugin.CatalogPlugin.Make(Platform)`
3. Start: `Platform.makePlatform(~version=..., ~plugins=[...])`

## Configuration Files

### `package.json`

Dependencies on Reventless framework packages, spec packages from other plugins, and Jest configuration for testing.

### `rescript.json`

ReScript compiler config with namespace, PPX flags, and dependency ordering. The namespace determines the module path: `CatalogPlugin.CatalogPlugin.Make(Platform)`.

## What You Can Modify

All generated code is regular ReScript — modify freely:
- Add fields to commands/events
- Add new guard conditions in `decide`
- Change projection logic in `project`
- Add new slices or read models
- Adjust wiring in the plugin composition root

After modifications, run `npm run build` to verify everything compiles, then `npm test` to run tests.
