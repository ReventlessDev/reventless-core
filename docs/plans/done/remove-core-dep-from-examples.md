# Plan: Remove `reventless-core` dependency from example packages

## Context

All four example packages (`examples/aggregate/catalog`, `examples/aggregate/ordering`,
`examples/dcb/catalog`, `examples/dcb/ordering`) currently depend on `@reventlessdev/reventless-core`
despite the examples being platform-agnostic application code. They should only depend on
`reventless-spec` (for types and compile-time functors) and `reventless-in-memory` (for the
test platform). The dependency on core is accidental: two compile-time functors and one builder
were placed in core rather than spec/platform.

### Root Causes

Three things in the example source files require `reventless-core`:

1. **`ReventlessCore.ExtensionPointMapping.Make`** — called in `CatalogPlugin.res` /
   `OrderingPlugin.res` to compile an EP mapping. The *types* (`Spec`, `Impl`, `T`) live in
   `reventless-spec`, but the `Make` functor body is in `reventless-core`. All functor
   dependencies (`Message`, `CommandTopic`, `Id`, `Schedule`, `QueryEngine`) are already in spec.

2. **`ReventlessCore.ExtensionMapping.Make`** — called in `OrdersExtension.res` /
   `ProductsExtension.res` to compile a mapping. Same situation as (1), except the functor also
   references `PluginExtensionPointSpec` for a routing special-case. `PluginExtensionPointSpec`
   is a pure type/spec file that lives in core only for historical reasons.

3. **`ReventlessCore.Extension_Builder.Make`** — called in plugin composition roots to build an
   extension component. Unlike Aggregate/ReadModel builders this functor needs no infrastructure
   adapter (Bus, DynamoDB, etc.); it is adapter-agnostic. It should be accessible through
   `Platform.T` so examples stay platform-neutral.

## Approach

### Step 1 — Move `PluginExtensionPointSpec` to `reventless-spec`

`PluginExtensionPointSpec` is a pure spec file (only `@schema` types and `let name`; includes
`Reventless.Plugin`). It belongs in spec, not core.

- **Move** `reventless/reventless-core/src/core/plugin/PluginExtensionPointSpec.res`
  → `reventless/reventless-spec/src/types/PluginExtensionPointSpec.res`
- **Delete** the original file in core.
- **Update** 7 files in `reventless-core` that reference bare `PluginExtensionPointSpec`.
  For files with many references, add `open Reventless.PluginExtensionPointSpec` at the top;
  for files with only 1–2 references, qualify as `Reventless.PluginExtensionPointSpec.*`:

  | File | Refs | Strategy |
  |------|------|----------|
  | `src/ExtensionMapping.res` | 2 | deleted in Step 3 anyway |
  | `src/core/ExtensionPoints/Plugin/PluginExtensionPoint_Builder.res` | 2 | `open Reventless.PluginExtensionPointSpec` |
  | `src/core/ExtensionPoints/Plugin/PluginExtensionPoint_Plugin.res` | 5 | `open Reventless.PluginExtensionPointSpec` |
  | `src/core/Extensions/Connect/PluginConnectExtension_Builder.res` | 7 | `open Reventless.PluginExtensionPointSpec` |
  | `src/components/Extension/Extension_Operations.res` | 2 | qualify inline |
  | `src/components/Plugin/Plugin_Builder.res` | 2 | qualify inline |
  | `src/components/Heartbeat/Heartbeat_Callback.res` | 2 | qualify inline |

### Step 2 — Move `ExtensionPointMapping.Make` to `reventless-spec`

- **Merge** the `Make` functor body from
  `reventless/reventless-core/src/ExtensionPointMapping.res` into
  `reventless/reventless-spec/src/types/ExtensionPointMapping.res`.
  - Remove `open Reventless.ExtensionPointMapping` at the top of the functor source (now in
    the same file — types are already in scope).
  - All other dependencies (`Message`, `CommandTopic`, `Id`, `Schedule`, `QueryEngine`,
    `Aggregate.Spec`) are already in spec. No further changes needed.
- **Delete** `reventless/reventless-core/src/ExtensionPointMapping.res`.
- **Update** one call site in core:
  `src/core/ExtensionPoints/Plugin/PluginExtensionPoint_Plugin.res:148`:
  `ExtensionPointMapping.Make(...)` → `Reventless.ExtensionPointMapping.Make(...)`

### Step 3 — Move `ExtensionMapping.Make` to `reventless-spec`

- **Merge** the `Make` functor body from
  `reventless/reventless-core/src/ExtensionMapping.res` into
  `reventless/reventless-spec/src/types/ExtensionMapping.res`.
  - Remove `open Reventless.ExtensionMapping` (now in the same file).
  - Change `open PluginExtensionPointSpec` → keep as-is: after Step 1, this resolves to the
    local spec module `Reventless.PluginExtensionPointSpec` (within the `Reventless` namespace
    no qualification is needed).
  - All other dependencies are in spec. ✓
- **Delete** `reventless/reventless-core/src/ExtensionMapping.res`.

### Step 4 — Add `module Extension` to `Platform.T`

In `reventless/reventless-spec/src/types/Platform.res`, add after `ExtensionPoint`:

```rescript
/** Factory for extension components (bidirectional EP↔aggregate bridges). */
module Extension: {
  module Make: (
    Spec: ExtensionMapping.Spec,
    Mappings: Extension.Mappings with module Spec := Spec,
  ) => Extension.T
}
```

### Step 5 — Implement `Platform.Extension.Make` in `reventless-in-memory`

In `reventless/reventless-in-memory/src/Platform.res`, add inside `module Make = ()`:

```rescript
module Extension = {
  module Make = (
    Spec: Reventless.ExtensionMapping.Spec,
    Mappings: Reventless.Extension.Mappings with module Spec := Spec,
  ): Reventless.Extension.T => ReventlessCore.Extension_Builder.Make(Spec, Mappings)
}
```

`reventless-in-memory` already depends on `reventless-core`, so this is valid.

### Step 6 — Implement `Platform.Extension.Make` in `reventless-aws`

In `reventless/reventless-aws/src/Platform.res`, add alongside `ExtensionPoint`:

```rescript
module Extension = {
  module Make = (
    Spec: Reventless.ExtensionMapping.Spec,
    Mappings: Reventless.Extension.Mappings with module Spec := Spec,
  ): Reventless.Extension.T => Extension_Builder.Make(Spec, Mappings)
}
```

(`Extension_Builder` here resolves to `ReventlessCore.Extension_Builder` which is already in
scope in `reventless-aws` via its dependency on core.)

### Step 7 — Update example source files

**Plugin composition roots** (4 files: `CatalogPlugin.res`, `OrderingPlugin.res` in both
`examples/aggregate/` and `examples/dcb/`):
- `ReventlessCore.ExtensionPointMapping.Make(...)` → `ExtensionPointMapping.Make(...)`
  (already in scope via `open Reventless` at the top of each file)
- `ReventlessCore.Extension_Builder.Make(EPSpec, Mappings)` → `Platform.Extension.Make(EPSpec, Mappings)`

**Extension implementation files** (4 files: `OrdersExtension.res`, `ProductsExtension.res`
in both `examples/aggregate/` and `examples/dcb/`):
- `ReventlessCore.ExtensionMapping.Make(...)` → `ExtensionMapping.Make(...)`
  (already in scope via `open Reventless.ExtensionMapping`)
- `ReventlessCore.ExtensionMapping.T` → `ExtensionMapping.T`

### Step 8 — Remove `reventless-core` from example dependencies

For each of the 4 example packages, update both `package.json` and `rescript.json`:
- Remove `@reventlessdev/reventless-core` from `dependencies` / `"dependencies"` list
- Remove `@reventlessdev/rescript-pulumi-pulumi` from `rescript.json` `"dependencies"` list
  (only needed transitively via core; examples do not reference Pulumi types directly)
- Run `npm install` from monorepo root to sync `package-lock.json`

## Files Changed

| File | Change |
|------|--------|
| `reventless-spec/src/types/PluginExtensionPointSpec.res` | **NEW** (moved from core) |
| `reventless-spec/src/types/ExtensionMapping.res` | Add `Make` functor |
| `reventless-spec/src/types/ExtensionPointMapping.res` | Add `Make` functor |
| `reventless-spec/src/types/Platform.res` | Add `module Extension` to `T` |
| `reventless-core/src/core/plugin/PluginExtensionPointSpec.res` | **DELETE** |
| `reventless-core/src/ExtensionMapping.res` | **DELETE** |
| `reventless-core/src/ExtensionPointMapping.res` | **DELETE** |
| `reventless-core/src/core/ExtensionPoints/Plugin/PluginExtensionPoint_Builder.res` | Qualify `PluginExtensionPointSpec` |
| `reventless-core/src/core/ExtensionPoints/Plugin/PluginExtensionPoint_Plugin.res` | Qualify + update `ExtensionPointMapping.Make` call |
| `reventless-core/src/core/Extensions/Connect/PluginConnectExtension_Builder.res` | Qualify `PluginExtensionPointSpec` |
| `reventless-core/src/components/Extension/Extension_Operations.res` | Qualify `PluginExtensionPointSpec` |
| `reventless-core/src/components/Plugin/Plugin_Builder.res` | Qualify `PluginExtensionPointSpec` |
| `reventless-core/src/components/Heartbeat/Heartbeat_Callback.res` | Qualify `PluginExtensionPointSpec` |
| `reventless-in-memory/src/Platform.res` | Add `module Extension` |
| `reventless-aws/src/Platform.res` | Add `module Extension` |
| `examples/aggregate/catalog/src/CatalogPlugin.res` | Update to spec / `Platform.Extension` refs |
| `examples/aggregate/catalog/src/Extension/OrdersExtension.res` | Update to spec refs |
| `examples/aggregate/ordering/src/OrderingPlugin.res` | Update to spec / `Platform.Extension` refs |
| `examples/aggregate/ordering/src/Extension/ProductsExtension.res` | Update to spec refs |
| `examples/dcb/catalog/src/Plugin/CatalogPlugin.res` | Update to spec / `Platform.Extension` refs |
| `examples/dcb/catalog/src/Extension/OrdersExtension.res` | Update to spec refs |
| `examples/dcb/ordering/src/Plugin/OrderingPlugin.res` | Update to spec / `Platform.Extension` refs |
| `examples/dcb/ordering/src/Extension/ProductsExtension.res` | Update to spec refs |
| `examples/*/package.json` (×4) | Remove `reventless-core` dep |
| `examples/*/rescript.json` (×4) | Remove `reventless-core` and `rescript-pulumi-pulumi` deps |

## Verification

1. `npm run build` from monorepo root — all packages compile without errors or warnings
2. `npm run test` from monorepo root — all existing tests pass
3. Confirm `@reventlessdev/reventless-core` no longer appears in any `examples/*/package.json`
   or `examples/*/rescript.json`
