# Zero-Touch Plugin Assembly

**Status:** Analysis  
**Date:** 2026-04-13  
**Context:** Currently, adding any new component to a plugin requires editing the plugin composition root (`CatalogPlugin.res` / `OrderingPlugin.res`). This analysis explores how to eliminate that edit entirely — a developer creates a file in the right folder and it is automatically included on the next build.

---

## Current Mechanism

Every plugin has a composition root that wires all components explicitly. For the DCB catalog:

```rescript
module Make = (Platform: ReventlessInfra.Platform.T) => {
  module AddProductSlice = Platform.StateChangeSlice.Make(AddProduct)
  // ...
  let make = () =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~heartbeatInterval=60,
      ~stateChangeSlices=[module(AddProductSlice), ...],
      ~stateViewSlices=[module(ProductsViewSlice), ...],
    )
}
```

For the aggregate catalog:

```rescript
module Make = (Platform: ReventlessInfra.Platform.T) => {
  module ProductAggregate = Platform.Aggregate.Make(Product, ProductBehavior, ReventlessInfra.NoEventMappings.Make(Product))
  @reventless.projections
  module ProductProjections: Mappings with module Target := ProductsReadModel = {
    let mappings: array<module(Mapping)> = [module(ProductsProjections.ProductMapping)]
  }
  module ProductReadModel = Platform.ReadModel.Make(ProductsReadModel, ProductProjections)
  // ...
  let make = () =>
    Platform.Plugin.make(~name="Catalog", ~heartbeatInterval=60, ~aggregates=[...], ~readModels=[...])
}
```

Every new component means editing this file.

---

## Hard Constraint: Compile-Time Modules

ReScript's `array<module(StateChangeSlice.T)>` is a **compile-time construct**. Modules cannot be collected at runtime through reflection. Any auto-discovery must produce ReScript source code that is then compiled.

---

## Folder Convention

The folder name already encodes the component type. The `Slice` suffix is optional, plural forms are accepted, and a chapter folder above is optional — the scanner matches any directory at any depth under `src/` (excluding `Plugin/`, `tests/`, and `lib/`).

### DCB slice types

| Folder name (case-sensitive) | `Plugin.make` parameter |
|---|---|
| `StateChange`, `StateChanges`, `StateChangeSlice`, `StateChangeSlices` | `~stateChangeSlices` |
| `StateView`, `StateViews`, `StateViewSlice`, `StateViewSlices` | `~stateViewSlices` |
| `Automation`, `Automations`, `AutomationSlice`, `AutomationSlices` | `~automationSlices` |
| `InboundTranslation`, `InboundTranslations`, `InboundTranslationSlice`, `InboundTranslationSlices` | `~inboundTranslationSlices` |
| `OutboundTranslation`, `OutboundTranslations`, `OutboundTranslationSlice`, `OutboundTranslationSlices` | `~outboundTranslationSlices` |

### Aggregate-style components

| Folder name | `Plugin.make` parameter | Notes |
|---|---|---|
| `Aggregate` or `Aggregates` | `~aggregates` | See pairing rule |
| `ReadModel` or `ReadModels` | `~readModels` | See pairing rule |
| `Task` or `Tasks` | `~tasks` | One file per task |
| `ExtensionPoint` or `ExtensionPoints` | `~extensionPoints` | See multi-mapping rule |
| `Extension` or `Extensions` | `~extensions` | One mapping per file |

### Valid source layouts

All of these are recognized without configuration:

```
src/
  Product/StateChangeSlice/AddProduct.res       ← chapter + Slice suffix
  Category/StateChange/AddCategory.res          ← chapter, no Slice suffix
  StateViewSlice/ProductsView.res               ← no chapter, Slice suffix
  StateView/CategoriesView.res                  ← no chapter, no Slice suffix
  Aggregate/Product.res                         ← flat aggregate folder
  Product/Aggregate/Product.res                 ← aggregate under chapter
```

---

## Component Discovery Rules

### DCB slices (simple)

All `.res` files in a recognized DCB slice folder are slice specs. No pairing needed.

Files excluded from all discovery: `*Test.res`, `*Fixtures.res`.

**Generated entry for each slice:**
```rescript
module AddProductSlice = Platform.StateChangeSlice.Make(AddProduct)
// → added to stateChangeSlices array
```

---

### Aggregates (paired)

Files are matched in pairs by stem: `Foo.res` + `FooBehavior.res`. The spec is `Foo`, the behavior is `FooBehavior`. Files whose name ends in `Behavior` are not registered as specs.

**EventMappings:** By default, `ReventlessInfra.NoEventMappings.Make(AggSpec)` is used. If a file named `{AggName}_EventMappings.res` exists anywhere under `src/EventMappings/`, it is used instead.

**Generated entry:**
```rescript
// default
module ProductAggregate = Platform.Aggregate.Make(
  Product,
  ProductBehavior,
  ReventlessInfra.NoEventMappings.Make(Product),
)

// with custom event mappings (Order_EventMappings.res present)
module OrderAggregate = Platform.Aggregate.Make(
  Order,
  OrderBehavior,
  Order_EventMappings,
)
```

---

### ReadModels (paired + projections convention)

Files are matched in pairs by stem: `FooReadModel.res` + `FooProjections.res`. ReadModels without a paired Projections file are not registered.

**Required convention change:** `FooProjections.res` must export a top-level `let allMappings` value listing all its mapping sub-modules. This moves the mapping list from the plugin composition root into the projections file itself:

```rescript
// Before (in CatalogPlugin.res):
module ProductProjections: Mappings with module Target := ProductsReadModel = {
  let mappings: array<module(Mapping)> = [module(ProductsProjections.ProductMapping)]
}

// After (in ProductsProjections.res — the projections file itself):
let allMappings: array<module(Mapping)> = [module(ProductMapping)]
```

**Generated entry:**
```rescript
@reventless.projections
module ProductsProjectionsWrapper: Mappings with module Target := ProductsReadModel = {
  let mappings = ProductsProjections.allMappings
}
module ProductsReadModelMaker = Platform.ReadModel.Make(ProductsReadModel, ProductsProjectionsWrapper)
```

---

### ExtensionPoints

All `*ExtensionPointMapping.res` files in an `ExtensionPoint[s]/` folder are registered.

#### Prerequisite: drop `Config: {let moduleUrl}` from `Platform.ExtensionPoint.Make`

The current signature is:
```rescript
module Make: (
  Mapping: ExtensionPointMapping.Mapping,
  Config: {let moduleUrl: string},
) => ExtensionPoint.T
```

The `Config.moduleUrl` was introduced to pass the plugin composition root's URL as `mappingsModulePath` to the AWS Lambda bundler — it told the bundler which file to `import()` for mapping logic and which package to include in the code archive.

This was a historical artifact: in the old world the plugin root was where mappings were assembled. But the `*ExtensionPointMapping.res` file IS where the mapping logic lives, and it already carries `moduleUrl` via `@@reventless.spec`. Using `Mapping.moduleUrl` as `mappingsModulePath` in `ExtensionPoint_Builder.Make` is correct and sufficient — the Lambda needs to import the mapping file, not the plugin root.

**Framework change required:** In `reventless-aws/src/components/ExtensionPoint_Builder.res`, replace `Mappings.moduleUrl` with the mapping file's `moduleUrl` (which is already available as part of the `Mapping` module). After this change, `Platform.ExtensionPoint.Make` drops `Config` and aligns with `Platform.Extension.Make`:

```rescript
// After the framework change:
module Make: (
  Mapping: ExtensionPointMapping.Mapping,
) => ExtensionPoint.T
```

#### Single-mapping ExtensionPoint (most common)

One `*ExtensionPointMapping.res` file → `Platform.ExtensionPoint.Make`:

```rescript
module ProductsExtensionPoint = Platform.ExtensionPoint.Make(ProductsExtensionPointMapping)
```

#### Multi-mapping ExtensionPoints

Multiple mappings for the **same** extension point go in a named subfolder. The subfolder name identifies the EP; its files are the individual mappings:

```
ExtensionPoint/
  Products/
    AddProductMapping.res
    ChangeProductMapping.res
```

The generator counts the files and selects the appropriate variant — all cases are fully generated, no hand-authored file needed:

| Mapping files | Generated call |
|---|---|
| 1 | `Platform.ExtensionPoint.Make(Mapping1)` |
| 2 | `Platform.ExtensionPoint.Make2(Mapping1, Mapping2)` |
| 3 | `Platform.ExtensionPoint.Make3(Mapping1, Mapping2, Mapping3)` |
| 4+ | `Platform.ExtensionPoint.MakeMulti(...)` with inline module expression |

For 4+, the generator produces an inline module expression. ReScript supports passing struct expressions directly to functor arguments, and every field in `ExtensionPoint.Mappings` can be derived from the discovered files:
- `module Spec` — from `Mapping1.ExtensionPoint` (all files in the subfolder share the same EP)
- `module type Mapping` — fixed boilerplate
- `let name` — `Spec.name`
- `let moduleUrl` — `%raw(\`import.meta.url\`)`
- `let mappings` — the discovered files in alphabetical order

```rescript
// → fully generated for 4+ mapping files in ExtensionPoint/Products/:
module ProductsExtensionPoint = Platform.ExtensionPoint.MakeMulti({
  module Spec = AddProductMapping.ExtensionPoint
  module type Mapping = ReventlessInfra.ExtensionPointMapping.T with module ExtensionPoint := Spec
  let name = Spec.name
  let moduleUrl: string = %raw(`import.meta.url`)
  let mappings: array<module(Mapping)> = [
    module(AddProductMapping),
    module(ChangeProductMapping),
    module(ArchiveProductMapping),
    module(SetProductPriceMapping),
  ]
})
```

---

### Extensions

All `.res` files in an `Extension[s]/` folder are registered.

**Convention:** Each extension file contains exactly one mapping module named `Mapping`. One delegate = one file. `Plugin.make` auto-merges all blueprints targeting the same extension point, so multiple extension files connecting to the same EP simply all go into the `~extensions` array:

```rescript
// Before (OrdersExtension.res):
module DemandMapping = { ... }
// Used as: Platform.Extension.Make(OrdersExtension.DemandMapping)

// After (OrdersExtension.res):
module Mapping = { ... }
// Used as: Platform.Extension.Make(OrdersExtension.Mapping)
```

**Multi-delegate extensions (multiple mappings to same EP):** Split into one file per delegate. The framework merges them automatically via `Plugin.make`'s blueprint grouping — no generator involvement needed.

**Generated entry per file:**
```rescript
module OrdersExtension = Platform.Extension.Make(OrdersExtension.Mapping)
// → added to extensions array; Plugin.make groups and merges by EP name
```

---

### Tasks

All `.res` files in a `Task[s]/` folder are registered as tasks.

**Generated entry:**
```rescript
module ImportProductsTask = Platform.Task.Make(ImportProducts)
```

---

## Conditional Exclusion

To exclude a component from registration without deleting it (e.g., in-progress, environment-specific, feature-flagged), add it to the `"exclude"` list in `plugin.json`:

```json
{
  "exclude": [
    "Product/StateChangeSlice/ExperimentalFeature.res",
    "Analytics/StateView/InternalMetrics.res"
  ]
}
```

Paths are relative to `src/`. Glob patterns are supported:

```json
{
  "exclude": [
    "Analytics/**"
  ]
}
```

The generator skips any file matching an exclude pattern before applying discovery rules. Excluded files remain in the repo and compile normally — they are simply not wired into the plugin.

---

## Plugin Configuration: `plugin.json`

An optional `plugin.json` at `src/Plugin.json` (co-located with the generated file) overrides defaults:

```json
{
  "heartbeatInterval": 60,
  "exclude": []
}
```

Both fields have defaults — `plugin.json` is never required:

| Field | Default | Derivation |
|---|---|---|
| `name` | Derived from package name | Unscoped npm package name, hyphens/underscores removed, each word capitalized. `catalog` → `"Catalog"`, `online-shop-catalog` → `"OnlineShopCatalog"`. |
| `heartbeatInterval` | `60` | Reasonable production default; override for high-frequency or low-frequency plugins. |
| `exclude` | `[]` | No exclusions by default. |

The generator never errors on a missing `plugin.json` — it applies defaults and proceeds.

---

## Generated Plugin File

The generated file is `src/Plugin.res`. It replaces the hand-authored `CatalogPlugin.res`. The `Plugin/` folder is eliminated.

### Plugin.make parameter order

Matches `Plugin_Builder.make` exactly:

```
~name, ~heartbeatInterval,
~extensionPoints, ~extensions,
~aggregates, ~readModels, ~tasks,
~stateChangeSlices, ~stateViewSlices, ~automationSlices,
~outboundTranslationSlices, ~inboundTranslationSlices
```

### DCB catalog — full generated `src/Plugin.res`

```rescript
// AUTO-GENERATED — do not edit. Run `npm run generate` to update.
// Source: src/   Config: src/plugin.json

module Make = (Platform: ReventlessInfra.Platform.T) => {
  // StateChangeSlices
  module AddProductSlice = Platform.StateChangeSlice.Make(AddProduct)
  module ChangeProductDescriptionSlice = Platform.StateChangeSlice.Make(ChangeProductDescription)
  module ChangeProductNameSlice = Platform.StateChangeSlice.Make(ChangeProductName)
  module ChangeProductPriceSlice = Platform.StateChangeSlice.Make(ChangeProductPrice)
  module AddCategorySlice = Platform.StateChangeSlice.Make(AddCategory)
  module ArchiveCategorySlice = Platform.StateChangeSlice.Make(ArchiveCategory)
  module RenameCategorySlice = Platform.StateChangeSlice.Make(RenameCategory)
  module RecordProductDemandSlice = Platform.StateChangeSlice.Make(RecordProductDemand)

  // StateViewSlices
  module CategoriesViewSlice = Platform.StateViewSlice.Make(CategoriesView)
  module ProductDemandViewSlice = Platform.StateViewSlice.Make(ProductDemandView)
  module ProductsViewSlice = Platform.StateViewSlice.Make(ProductsView)

  // InboundTranslationSlices
  module ImportProductSlice = Platform.InboundTranslationSlice.Make(ImportProduct)

  // ExtensionPoints
  module ProductsExtensionPoint = Platform.ExtensionPoint.Make(ProductsExtensionPointMapping)

  // Extensions
  module OrdersExtension = Platform.Extension.Make(OrdersExtension.Mapping)

  let make = () =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~heartbeatInterval=60,
      ~extensionPoints=[module(ProductsExtensionPoint)],
      ~extensions=[module(OrdersExtension)],
      ~stateChangeSlices=[
        module(AddProductSlice),
        module(ChangeProductDescriptionSlice),
        module(ChangeProductNameSlice),
        module(ChangeProductPriceSlice),
        module(AddCategorySlice),
        module(ArchiveCategorySlice),
        module(RenameCategorySlice),
        module(RecordProductDemandSlice),
      ],
      ~stateViewSlices=[
        module(CategoriesViewSlice),
        module(ProductDemandViewSlice),
        module(ProductsViewSlice),
      ],
      ~inboundTranslationSlices=[module(ImportProductSlice)],
    )
}
```

### Aggregate catalog — full generated `src/Plugin.res`

```rescript
// AUTO-GENERATED — do not edit. Run `npm run generate` to update.
open Reventless.Projection

module Make = (Platform: ReventlessInfra.Platform.T) => {
  // Aggregates
  module CategoryAggregate = Platform.Aggregate.Make(
    Category, CategoryBehavior, ReventlessInfra.NoEventMappings.Make(Category),
  )
  module ProductAggregate = Platform.Aggregate.Make(
    Product, ProductBehavior, ReventlessInfra.NoEventMappings.Make(Product),
  )
  module ProductDemandAggregate = Platform.Aggregate.Make(
    ProductDemand, ProductDemandBehavior, ReventlessInfra.NoEventMappings.Make(ProductDemand),
  )

  // ReadModels
  @reventless.projections
  module CategoriesProjectionsWrapper: Mappings with module Target := CategoriesReadModel = {
    let mappings = CategoriesProjections.allMappings
  }
  module CategoryReadModel = Platform.ReadModel.Make(CategoriesReadModel, CategoriesProjectionsWrapper)

  @reventless.projections
  module ProductsProjectionsWrapper: Mappings with module Target := ProductsReadModel = {
    let mappings = ProductsProjections.allMappings
  }
  module ProductReadModel = Platform.ReadModel.Make(ProductsReadModel, ProductsProjectionsWrapper)

  @reventless.projections
  module ProductDemandProjectionsWrapper: Mappings with module Target := ProductDemandReadModel = {
    let mappings = ProductDemandProjections.allMappings
  }
  module ProductDemandReadModelMaker = Platform.ReadModel.Make(ProductDemandReadModel, ProductDemandProjectionsWrapper)

  // ExtensionPoints
  module ProductsExtensionPoint = Platform.ExtensionPoint.Make(ProductsExtensionPointMapping)

  // Extensions
  module OrdersExtension = Platform.Extension.Make(OrdersExtension.Mapping)

  // Tasks
  module ImportProductsTask = Platform.Task.Make(ImportProducts)

  let make = () =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~heartbeatInterval=60,
      ~extensionPoints=[module(ProductsExtensionPoint)],
      ~extensions=[module(OrdersExtension)],
      ~aggregates=[
        module(CategoryAggregate),
        module(ProductAggregate),
        module(ProductDemandAggregate),
      ],
      ~readModels=[
        module(CategoryReadModel),
        module(ProductReadModel),
        module(ProductDemandReadModelMaker),
      ],
      ~tasks=[module(ImportProductsTask)],
    )
}
```

The original `CatalogPlugin.res` and the `Plugin/` folder are deleted. The platform wiring file (`platform-in-memory/src/Main.res`) references `Plugin` instead of `CatalogPlugin`:

```rescript
// Before:
module CatalogMaker = CatalogPlugin.Make(Platform)
// After (module name is now just the package namespace):
module CatalogMaker = Catalog.Plugin.Make(Platform)
```

---

## Required Convention Changes

### 1. Extension files: standardize inner module name to `Mapping`

| File | Before | After |
|---|---|---|
| `OrdersExtension.res` | `module DemandMapping = {...}` | `module Mapping = {...}` |
| `ProductsExtension.res` | `module ProductMapping = {...}` | `module Mapping = {...}` |

All callers: `OrdersExtension.DemandMapping` → `OrdersExtension.Mapping`.

### 2. Projections files: add `allMappings` export

Each `*Projections.res` file adds one line aggregating its mapping modules:

```rescript
// ProductsProjections.res — add at the end
let allMappings: array<module(Mapping)> = [module(ProductMapping)]

// CategoriesProjections.res
let allMappings: array<module(Mapping)> = [module(CategoryMapping)]

// ProductDemandProjections.res
let allMappings: array<module(Mapping)> = [
  module(ProductMapping),
  module(ProductDemandMapping),
]
```

---

## Generator Implementation

The generator lives in `reventless-spec` as a compiled ReScript binary. It belongs there because it encodes exactly the same component type / folder name mapping that the spec package defines — keeping the two in sync in one package.

### Language: ReScript

The generator is written in ReScript and compiled to a Node.js entry point. This is the natural choice:
- The folder→component-type mapping is framework knowledge that belongs next to the spec types, not as an ad-hoc JS script
- ReScript's type system catches mistakes in the generator itself (e.g. a missing slice type in the mapping table)
- Consistent with the rest of the codebase — no context-switching to JS

The compiled output (`src/generator/PluginGenerator.res.mjs`) is invoked as a Node.js script via the `bin` entry. ReScript's ESM output runs directly under Node v22 with no transpilation step.

```json
// reventless-spec/package.json
{
  "bin": {
    "generate-plugin": "./src/generator/PluginGenerator.res.mjs"
  }
}
```

Plugin packages call it via `npm run generate`:

```json
// catalog/package.json
{
  "scripts": {
    "generate": "generate-plugin src/",
    "prebuild": "npm run generate",
    "build": "rescript build"
  }
}
```

### Source location

```
reventless-spec/src/generator/
  PluginGenerator.res      ← entry point: parse args, orchestrate, write file
  Discovery.res            ← walk src/, classify folders, apply exclude patterns
  Pairing.res              ← pair Aggregate+Behavior, ReadModel+Projections
  Codegen.res              ← render each component type to ReScript source lines
  Config.res               ← read plugin.json, apply defaults, derive plugin name
```

### Generator steps

1. Accept a `src/` path as argument (`Process.argv`)
2. Read `plugin.json` via `Config.read`; apply defaults for missing fields
3. Walk all subdirectories via `Discovery.scan`; match component folders by name; apply `"exclude"` patterns
4. Group discovered files by component type; apply pairing rules via `Pairing.resolve`
5. For ExtensionPoint subfolders: count mapping files, select `Make` / `Make2` / `Make3` / `MakeMulti` variant
6. Sort deterministically within each type (alphabetical by file stem)
7. Render source lines via `Codegen.render`
8. Write `src/Plugin.res` via `Fs.writeFileSync`

The Node.js bindings needed (`Fs`, `Path`, `Process`) are already available in `rescript-core` (`NodeJs` module).

The generated file is **committed to git**: changes are visible in code review, and CI can run `rescript build` without re-running the generator.

---

## Developer Workflow After This Change

**DCB: add a new StateChangeSlice:**
```
1. Create src/Product/StateChangeSlice/AddProductColor.res
2. npm run build   ← prebuild regenerates Plugin.res, rescript compiles
3. Done
```

**Aggregate: add a new aggregate:**
```
1. Create src/Aggregate/Warranty.res + src/Aggregate/WarrantyBehavior.res
2. npm run build
3. Done
```

**Add a ReadModel:**
```
1. Create src/ReadModel/WarrantiesReadModel.res
2. Create src/ReadModel/WarrantiesProjections.res  (with allMappings export)
3. npm run build
4. Done
```

**Exclude an in-progress component:**
```
1. Add "Product/StateChangeSlice/ExperimentalFeature.res" to "exclude" in plugin.json
2. npm run build
3. Done — file stays in repo, compiles, but is not wired into the plugin
```

**Change heartbeat interval:**
```
1. Edit src/plugin.json: { "heartbeatInterval": 30 }
2. npm run build
3. Done
```

---

## What Changes, What Stays the Same

| File | After | Why |
|---|---|---|
| `src/Plugin/CatalogPlugin.res` | **Deleted** | Replaced by `src/Plugin.res` |
| `src/Plugin.res` | **Auto-generated, committed** | Output of generator |
| `src/plugin.json` | **Optional, hand-authored** | Override defaults; not required |
| `src/*/StateChangeSlice/*.res` | Unchanged | Already valid |
| `src/*/Aggregate/Foo.res` | Unchanged | Already valid |
| `src/*/Aggregate/FooBehavior.res` | Unchanged | Already valid |
| `src/*/ReadModel/FooProjections.res` | **Add `allMappings` export** | One new line per file |
| `src/*/Extension/FooExtension.res` | **Rename inner module to `Mapping`** | One rename per file |
| `platform-in-memory/src/Main.res` | **Update module reference** | `CatalogPlugin.Make` → `Catalog.Plugin.Make` |

---

## Scope Not Covered

- **`SideEffect` components** (`Order_EmailNotification.res`): not yet a first-class `Plugin.make` parameter. If added to the framework, discovery follows the same folder pattern.
- **`Service` components** (`EmailService.res`): not a plugin component; stays out of scope.
