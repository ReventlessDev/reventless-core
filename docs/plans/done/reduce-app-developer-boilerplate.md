# Reduce App Developer Boilerplate

## Status: BACKLOG

## Goal

Minimize ceremony in app-level plugin code by having Platform factories generate wrapper modules internally. App developers should express domain intent, not framework plumbing.

---

## Problem

Beyond the `~scheduler, ~api, ~apiRole` pass-through (tracked in `remove-platform-plumbing-from-plugin-make.md`), app plugins contain significant boilerplate that exists only to satisfy framework module types.

### 1. Extension/ExtensionPoint Mappings wiring (~15 lines per EP/Extension)

Every extension point or extension in a plugin requires three steps:

```rescript
// Step 1: Wrap mapping with ReventlessInfra.ExtensionPointMapping.Make
module ProductsEPMappingT = ReventlessInfra.ExtensionPointMapping.Make(
  CatalogSpec.ProductsExtensionPoint,
  ProductsExtensionPointMapping,
)
// Step 2: Create Mappings module with boilerplate fields
module ProductsEPMappings = {
  module Spec = CatalogSpec.ProductsExtensionPoint
  module type Mapping = ReventlessInfra.ExtensionPointMapping.T with module ExtensionPoint := Spec
  let name = "ProductsEPMappings"
  let moduleUrl: string = %raw(`import.meta.url`)
  let mappings: array<module(Mapping)> = [module(ProductsEPMappingT)]
}
// Step 3: Call Platform factory
module ProductsExtensionPointMaker = Platform.ExtensionPoint.Make(
  CatalogSpec.ProductsExtensionPoint,
  ProductsEPMappings,
)
```

The app dev only cares about: "this plugin exposes ProductsExtensionPoint using ProductsExtensionPointMapping".

**Ideal**:
```rescript
module ProductsExtensionPointMaker = Platform.ExtensionPoint.Make(
  CatalogSpec.ProductsExtensionPoint,
  ProductsExtensionPointMapping,
)
```

### 2. ReadModel Mappings wiring (~6 lines per read model)

```rescript
// Current:
module CategoryProjections: Mappings with module Target := CategoriesReadModel = {
  module M = Mappings.Make(CategoriesReadModel)
  module type Mapping = M.Mapping
  let moduleUrl: string = %raw(`import.meta.url`)
  let mappings: array<module(Mapping)> = [module(CategoriesProjections.CategoryMapping)]
}
module CategoryReadModel = Platform.ReadModel.Make(CategoriesReadModel, CategoryProjections)
```

The app dev just wants: "CategoriesReadModel is projected from CategoryMapping".

**Ideal**:
```rescript
module CategoryReadModel = Platform.ReadModel.Make(
  CategoriesReadModel,
  [module(CategoriesProjections.CategoryMapping)],
)
```

### 3. Fake `module Aggregate` adapter in Extension/EP mappings

Extension mappings that target DCB slices must wrap them as `Aggregate.Spec`:

```rescript
// In every Extension mapping file targeting a DCB slice:
module Aggregate = {
  let name = Target.name
  module Id = Id.String
  type command = Target.command
  let commandSchema = Target.commandSchema
  @schema type event = unit   // unused
  @schema type error = unit   // unused
  let moduleUrl: string = %raw(`import.meta.url`)
}
```

This is a framework leak — the extension system internally uses aggregate routing, but that's not the app developer's concern. The unused `event = unit` / `error = unit` are a code smell.

### 4. `let moduleUrl = %raw(\`import.meta.url\`)` in every spec

Every spec, mappings module, and adapter requires this line. It's a Lambda runtime concern (module resolution for bundled handlers) leaking into domain code.

---

## Approach

### Item 1: Simplify Extension/EP wiring

Change `Platform.ExtensionPoint.Make` and `Platform.Extension.Make` to accept the raw mapping module directly (without requiring the intermediate Mappings wrapper):

```rescript
// New Platform.ExtensionPoint.Make signature:
module Make: (
  Spec: ExtensionPointMapping.Spec,
  Mapping: ExtensionPointMapping.RawMapping with module ExtensionPoint := Spec,
) => ExtensionPoint.T
```

The `Make` functor generates the Mappings wrapper internally (name, moduleUrl, array wrapping). For multi-mapping cases, provide an overload or a `MakeMulti` variant.

**Investigation needed**: Can `moduleUrl` be derived from the mapping module's own `moduleUrl`, or does it need to come from the plugin file? If the latter, this limits how much we can simplify.

### Item 2: Simplify ReadModel Mappings

Similar approach — `Platform.ReadModel.Make` could accept an array of mapping modules directly:

```rescript
module Make: (
  Spec: Reventless.ReadModel.Spec,
  Mapping: Reventless.Projection.Mapping with module Target := Spec,
) => ReadModel.T with module Spec = Spec
```

Or for multiple mappings, accept an array. The `Mappings` wrapper module would be generated internally.

**Constraint**: ReScript first-class module arrays in functor arguments may require a different encoding than the current `Mappings` module type. Needs prototyping.

### Item 3: Auto-generate DCB aggregate adapter

The Extension/EP mapping system could provide a helper functor that creates the fake Aggregate module from a DCB slice spec:

```rescript
// In ReventlessInfra:
module DcbSliceAsAggregate = {
  module Make = (Target: { let name: string; type command; let commandSchema: S.t<command> }) => {
    let name = Target.name
    module Id = Reventless.Id.String
    type command = Target.command
    let commandSchema = Target.commandSchema
    @schema type event = unit
    @schema type error = unit
    let moduleUrl: string = %raw(`import.meta.url`)
  }
}
```

Then extension mapping files just write:
```rescript
module Aggregate = ReventlessInfra.DcbSliceAsAggregate.Make(Target)
```

Instead of 8 lines of manual wiring.

**Alternative**: Refactor ExtensionMapping to not require Aggregate.Spec at all — accept a simpler "command target" type. This is cleaner but a deeper change.

### Item 4: Eliminate `moduleUrl` from app code

Options:
- **PPX**: A `@moduleUrl` attribute that generates the binding automatically (heavy — new PPX dependency)
- **Convention**: Framework derives module paths from component names + a base path config (fragile)
- **Functor default**: `Platform.*.Make` generates `moduleUrl` internally using the plugin name + component name (possible if module resolution can be standardized)

This is the lowest-impact item — one line per file. Investigate only after items 1-3.

---

## Files to investigate

| Area | Key files |
|------|-----------|
| EP Make | `reventless-infra/src/components/ExtensionPoint.res`, `reventless-core/src/components/ExtensionPoint/ExtensionPoint_Builder.res` |
| Extension Make | `reventless-infra/src/components/Extension.res`, `reventless-core/src/components/Extension/Extension_Builder.res` |
| ReadModel Make | `reventless-infra/src/components/ReadModel.res`, `reventless-core/src/components/ReadModel/ReadModel_Builder.res` |
| EP/Extension Mapping | `reventless-infra/src/components/ExtensionPointMapping.res`, `reventless-infra/src/components/ExtensionMapping.res` |
| Example plugins | `examples/online-shop-hybrid/*/src/Plugin/*Plugin.res` |

---

## Sequencing

1. **Item 3** (DcbSliceAsAggregate helper) — smallest, self-contained, immediate value
2. **Item 1** (EP/Extension wiring) — biggest boilerplate reduction, needs moduleUrl investigation
3. **Item 2** (ReadModel Mappings) — moderate reduction, may need ReScript prototyping
4. **Item 4** (moduleUrl elimination) — investigate last, lowest priority

Each item is independent and can be done in any order.

---

## Implementation Plan

The approach changes only the **Platform.T interface** and its implementations (AWS, InMemory). Core builders (`ExtensionPoint_Builder`, `Extension_Builder`, `ReadModel_Builder`) remain unchanged — Platform implementations construct the full `Mappings` container internally before delegating to them.

### Phase 1: DcbSliceAsAggregate Helper (Item 3)

**Goal**: 8 lines → 1 line for the fake Aggregate module in DCB extension mappings.

**Add `DcbSliceAsAggregate` functor** to `reventless/reventless-infra/src/types/ExtensionMapping.res` after existing `NoAggregate` (line 148):

```rescript
module DcbSliceAsAggregate = {
  module Make = (Target: {
    let name: string
    type command
    let commandSchema: S.t<command>
    let moduleUrl: string
  }): (Reventless.Aggregate.Spec with type command = Target.command) => {
    let name = Target.name
    module Id = Reventless.Id.String
    type command = Target.command
    let commandSchema = Target.commandSchema
    @schema type event = unit
    @schema type error = unit
    let moduleUrl = Target.moduleUrl
  }
}
```

The Target (StateChangeSlice spec) already has `name`, `command`, `commandSchema`, `moduleUrl` — the functor input is satisfied structurally.

**Update example files** — replace 8-line Aggregate blocks with 1-line functor call:
- `examples/online-shop-dcb/catalog/src/Extension/OrdersExtension.res`
- `examples/online-shop-dcb/ordering/src/Extension/ProductsExtension.res`
- `examples/online-shop-hybrid/catalog/src/Extension/OrdersExtension.res`
- `examples/online-shop-hybrid/ordering/src/Extension/ProductsExtension.res`

```rescript
// Before (8 lines):
module Aggregate = {
  let name = Target.name
  module Id = Id.String
  type command = Target.command
  let commandSchema = Target.commandSchema
  @schema type event = unit
  @schema type error = unit
  let moduleUrl: string = %raw(`import.meta.url`)
}

// After (1 line):
module Aggregate = ReventlessInfra.ExtensionMapping.DcbSliceAsAggregate.Make(Target)
```

**Verification**: Build `reventless-infra`, then both DCB and hybrid example catalogs and orderings.

### Phase 2: Simplify Extension Wiring (Item 1a)

**Goal**: 12 lines → 3 lines per Extension in plugin files.

Extension is the simplest to change because `Mappings.moduleUrl` is **never used** by any builder — Extension delegates directly from Platform to `Extension_Builder.Make` (in reventless-core), which only accesses `Mappings.name` and `Mappings.mappings`.

**Before (12 lines)**:
```rescript
module OrdersDemandMapping = ReventlessInfra.ExtensionMapping.Make(...)
module OrdersExtensionMappings = {
  module Spec = OrderingSpec.OrdersExtensionPoint
  module type Mapping = ReventlessInfra.ExtensionMapping.T with module ExtensionPoint := Spec
  let name = "CatalogDemand"
  let moduleUrl: string = %raw(`import.meta.url`)
  let mappings: array<module(Mapping)> = [module(OrdersDemandMapping)]
}
module OrdersExtensionMaker = Platform.Extension.Make(OrderingSpec.OrdersExtensionPoint, OrdersExtensionMappings)
```

**After (3 lines)**:
```rescript
module OrdersExtensionMaker = Platform.Extension.Make(
  OrderingSpec.OrdersExtensionPoint,
  OrdersExtension.DemandMapping,
)
```

**Files to change**:

| File | Change |
|------|--------|
| `reventless/reventless-infra/src/types/Platform.res` | Change `Extension.Make` to accept `Impl` instead of `Mappings` |
| `reventless/reventless-aws/src/Platform.res` | Compile mapping + construct Mappings container internally, delegate to core builder |
| `reventless/reventless-in-memory/src/Platform.res` | Same |
| 6 example plugin files | Remove `ExtensionMapping.Make` + Mappings wrapper, pass Impl directly |

**Platform.T signature change**:
```rescript
// Before:
module Extension: {
  module Make: (Spec: ExtensionMapping.Spec, Mappings: ExtensionMapping.Mappings with module Spec := Spec) => Extension.T
}
// After:
module Extension: {
  module Make: (Spec: ExtensionMapping.Spec, Impl: ExtensionMapping.Mapping with module ExtensionPoint := Spec) => Extension.T
}
```

**AWS/InMemory Platform implementation pattern**:
```rescript
module Extension = {
  module Make = (
    Spec: ReventlessInfra.ExtensionMapping.Spec,
    Impl: ReventlessInfra.ExtensionMapping.Mapping with module ExtensionPoint := Spec,
  ): ReventlessInfra.Extension.T => {
    module CompiledMapping = ReventlessInfra.ExtensionMapping.Make(Spec, Impl)
    module Mappings: ReventlessInfra.ExtensionMapping.Mappings with module Spec := Spec = {
      module type Mapping = ReventlessInfra.ExtensionMapping.T with module ExtensionPoint := Spec
      let name = Impl.Target.name
      let moduleUrl = Impl.Target.moduleUrl
      let mappings: array<module(Mapping)> = [module(CompiledMapping)]
    }
    ReventlessCore.Extension_Builder.Make(Spec, Mappings)
  }
}
```

**Component naming impact**: Extension component name changes from e.g. `"OrdersExtensionPoint.CatalogDemand"` to `"OrdersExtensionPoint.RecordProductDemand"` (uses `Impl.Target.name` instead of manual `Mappings.name`). This is a Pulumi state change but only affects the logical name, not infrastructure resources.

### Phase 3: Simplify ExtensionPoint Wiring (Item 1b)

**Goal**: 12 lines → 5 lines per ExtensionPoint in plugin files.

EP is harder than Extension because `Mappings.moduleUrl` IS used by the AWS builder for Lambda handler registration (`registerExtensionPoint`). The `moduleUrl` must point to a file in the app package — since `%raw(\`import.meta.url\`)` resolves at build time to the file where it appears, we need a `Config` module argument to carry it from the plugin file.

**Before (12 lines)**: (3 modules: Make mapping + Mappings wrapper + Platform.Make)

**After (5 lines)**:
```rescript
module ProductsExtensionPointMaker = Platform.ExtensionPoint.Make(
  CatalogSpec.ProductsExtensionPoint,
  ProductsExtensionPointMapping,
  { let moduleUrl: string = %raw(`import.meta.url`) },
)
```

**Files to change**:

| File | Change |
|------|--------|
| `reventless/reventless-infra/src/types/Platform.res` | Change `ExtensionPoint.Make` to accept `Impl` + `Config` |
| `reventless/reventless-aws/src/Platform.res` | Compile mapping, build Mappings container with `Config.moduleUrl`, delegate to existing builder |
| `reventless/reventless-aws/src/components/ExtensionPoint_Builder.res` | No change — still receives full Mappings |
| `reventless/reventless-in-memory/src/Platform.res` | Same pattern (InMemory ignores moduleUrl but must match Platform.T) |
| 6 example plugin files | Simplify EP wiring |

**Platform.T signature change**:
```rescript
module ExtensionPoint: {
  module Make: (
    Spec: ExtensionPointMapping.Spec,
    Impl: ExtensionPointMapping.Mapping with module ExtensionPoint := Spec,
    Config: { let moduleUrl: string },
  ) => ExtensionPoint.T
}
```

### Phase 4: Simplify ReadModel Wiring (Item 2) — EXTRACTED

Extracted to separate backlog plan: `simplify-readmodel-mappings-wiring.md`

### Phase 5: Rename `module Aggregate` → `module Target` in Extension/EP Mappings

`module Aggregate` in `ExtensionMapping.Mapping` and `ExtensionPointMapping.Mapping` is a framework leak — the app developer is mapping commands to a *target*, which may or may not be an aggregate. In DCB context it's a StateChangeSlice.

**Changes**:
1. Rename `module Aggregate: Reventless.Aggregate.Spec` → `module Target: Reventless.Aggregate.Spec` in both `ExtensionMapping.Mapping` and `ExtensionPointMapping.Mapping`
2. Rename `DcbSliceAsAggregate` → `AsTarget` (adapts a DCB slice spec to satisfy the Target module type)
3. Update `ExtensionMapping.Make` / `ExtensionPointMapping.Make` internals (`Aggregate.name` → `Target.name`, etc.)
4. Update all extension mapping implementation files

**Before**:
```rescript
module DemandMapping = {
  module ExtensionPoint = OrderingSpec.OrdersExtensionPoint
  module Aggregate = DcbSliceAsAggregate.Make(Target)    // "Aggregate" is misleading
  let mapIncomingEvent = ...
}
```

**After**:
```rescript
module DemandMapping = {
  module ExtensionPoint = OrderingSpec.OrdersExtensionPoint
  module Target = AsTarget.Make(RecordProductDemand)      // clear intent
  let mapIncomingEvent = ...
}
```

For aggregate-based mappings the change is a simple rename: `module Aggregate = Product` → `module Target = Product`.

**Two DCB adapter patterns exist** — `AsTarget` only covers the first:

| Pattern | Used in | `AsTarget` helps? |
|---------|---------|-------------------|
| **Incoming** (Extension: EP events → StateChangeSlice commands) | `OrdersExtension.res`, `ProductsExtension.res` | Yes — `event = unit`, `error = unit` |
| **Outgoing** (EP mapping: DcbEventLog events → EP events) | `OrdersExtensionPointMapping.res`, `ProductsExtensionPointMapping.res` | No — needs custom event subset from the DcbEventLog |

The outgoing pattern currently defines a hand-written Target that redeclares a subset of events with full `Aggregate.Spec` shape:
```rescript
// OrdersExtensionPointMapping.res — current (verbose, requires DcbTag annotations)
module Target = {
  let name = "OrderingEventLog"
  module Id = Id.String
  @schema type command = unit
  @schema type event =
    | OrderPlaced({orderId: @s.matches(DcbTag.string) string, ...})
    | OrderCancelled({orderId: @s.matches(DcbTag.string) string, ...})
  @schema type error = unit
  let commandSchema = S.unit
  let moduleUrl: string = %raw(`import.meta.url`)
}
```

This is conceptually the same as `consumedEvent` in StateChangeSlice — a decoded subset of the DcbEventLog events. The same pattern applies to **both** mapping types:

- **ExtensionPointMapping** outgoing (`mapOutgoingEvent`): DcbEventLog events → EP events (uses `Target.event` to decode)
- **ExtensionMapping** outgoing (`mapOutgoingEvent`): DcbEventLog events → EP commands (uses `Target.event` to decode)

Both are decoding event subsets from the DcbEventLog. Both should follow the `consumedEvent` rules:

1. **Rename `type event` → `type consumedEvent`** in the Target — makes the intent explicit
2. **Drop `@s.matches(DcbTag.string)` annotations** — the mapping only *decodes* events, never writes them. Tags are for filtering/writing, not reading. (Same rule as StateChangeSlice's `consumedEvent`.)
3. **Allow field subsets** — only declare the fields the mapping actually uses, not the full event shape
4. **Validate compatibility** — extend `DcbValidation.validateProducedAndConsumed` to also check EP/Extension mapping event subsets against the DcbEventLog's produced events (same rules: every consumed variant must have a producer, consumed fields must exist in produced shape, types must be compatible)

**After** (cleaner, no tags, field subset allowed):
```rescript
module Target = {
  let name = "OrderingEventLog"
  module Id = Id.String
  @schema type consumedEvent =
    | OrderPlaced({orderId: string, customerId: string, productIds: array<string>})
    | OrderCancelled({orderId: string, productIds: array<string>})
  let moduleUrl: string = %raw(`import.meta.url`)
}
```

This is a deeper change than a rename — it requires changing both `ExtensionPointMapping.Make` and `ExtensionMapping.Make` to use `consumedEvent` instead of `event` for the outgoing path, and potentially a new simpler Target module type (not full `Aggregate.Spec`). The `command = unit`, `error = unit`, `commandSchema = S.unit` fields would no longer be needed.

The rename from `module Aggregate` to `module Target` still applies and makes the intent clearer in all patterns.

**Files to change**:
- `reventless-infra/src/types/ExtensionMapping.res` — Impl type + Make functor + rename helper
- `reventless-infra/src/types/ExtensionPointMapping.res` — Impl type + Make functor
- All extension/EP mapping implementation files in examples (both incoming and outgoing patterns)
- Platform implementations (Phase 2/3 code references `Impl.Target.name` / `Impl.Target.moduleUrl`)

### Phase 6: Multi-mapping + Custom Name Support

Phases 2/3 simplified the API to accept a single `Impl` module, which dropped two capabilities:
1. **Multiple mappings** per Extension/EP — the old `Mappings` container held an array
2. **Custom component name** — Extension's `Mappings.name` was used for Pulumi component naming (`Spec.name ++ "." ++ Mappings.name`). Now derived from `Impl.Target.name`, which can change Pulumi state and trigger resource recreation in existing deployments. (EP's `Mappings.name` was never accessed by any builder — no impact there.)

**Plan**: Add both `MakeMulti` variants and a `name` field to the Config module:

```rescript
// Platform.T — Extension
module Extension: {
  // Single mapping (simplified, current)
  module Make: (
    Spec: ExtensionMapping.Spec,
    Impl: ExtensionMapping.Mapping with module ExtensionPoint := Spec,
  ) => Extension.T

  // Multi mapping + custom name (full control)
  module MakeMulti: (
    Spec: ExtensionMapping.Spec,
    Mappings: ExtensionMapping.Mappings with module Spec := Spec,
  ) => Extension.T
}

// Platform.T — ExtensionPoint
module ExtensionPoint: {
  // Single mapping (simplified, current)
  module Make: (
    Spec: ExtensionPointMapping.Spec,
    Impl: ExtensionPointMapping.Mapping with module ExtensionPoint := Spec,
    Config: {let moduleUrl: string},
  ) => ExtensionPoint.T

  // Multi mapping + custom name (full control)
  module MakeMulti: (
    Spec: ExtensionPointMapping.Spec,
    Mappings: ExtensionPoint.Mappings with module Spec := Spec,
  ) => ExtensionPoint.T
}
```

`MakeMulti` restores the original full-Mappings API for cases that need multiple mappings or a custom name. This keeps the simple path simple and the power path available.

### Phase 7: Remove redundant `module ExtensionPoint` from Extension mapping Impls — DONE

`Platform.Extension.Make` uses destructive substitution (`Impl with module ExtensionPoint := Spec`), which removes `module ExtensionPoint` from the expected Impl type — the first `Spec` argument provides it. The `module ExtensionPoint = Source` alias in Extension mapping modules was redundant.

Removed from all 6 Extension mapping files (aggregates, DCB, hybrid).

### Phase 8: Rename `Impl` → `Mapping` everywhere

The module type name `Impl` and functor parameter name `Impl` are internal framework terms. From the app developer's perspective they're providing a **mapping**. Rename both the module type (`module type Impl` → `module type Mapping`) and functor parameters — matches how the values are named (`DemandMapping`, `ProductMapping`).

```rescript
// ExtensionMapping.res: module type Impl → module type Mapping
// ExtensionPointMapping.res: module type Impl → module type Mapping

// Platform.T
module Extension: {
  module Make: (
    Mapping: ExtensionMapping.Mapping,
  ) => Extension.T
}
module ExtensionPoint: {
  module Make: (
    Mapping: ExtensionPointMapping.Mapping with module ExtensionPoint := Spec,
    Config: {let moduleUrl: string},
  ) => ExtensionPoint.T
}
```

### Phase 9: Introduce `Delegate` module type + rename `producedEvent` → `event`

**Problem**: `module Target: Reventless.Aggregate.Spec` in extension/EP mapping Impls forces DCB slices to use an `AsTarget` adapter because `Aggregate.Spec` requires `event`, `error`, and `Id` which slices don't have. The `error` field is never used by mappings.

**Part A — Rename `module Target` → `module Delegate`** in `ExtensionMapping.Mapping` and `ExtensionPointMapping.Mapping`. "Delegate" captures both directions: commands are delegated to it, events come back from it.

**Part B — New `Delegate` module type** (without `error`):

```rescript
module type Delegate = {
  module Id: Id.T
  let name: string
  @schema type command
  @schema type event
  let commandSchema: S.t<command>
  let moduleUrl: string
}
```

Aggregates satisfy this structurally (extra `error` ignored). DCB slices still need adaptation because they have `producedEvent` instead of `event`.

**Part C — Rename `producedEvent` → `event` in StateChangeSlice** + add `module Id = Id.String`:

Only `StateChangeSlice` has `producedEvent` (other slice types don't). After renaming:

```rescript
// StateChangeSlice.Spec
module Id = Id.String           // added (always String for DCB)
@schema type event = ...        // renamed from producedEvent
@schema type consumedEvent = ...
```

StateChangeSlice specs then structurally satisfy `Delegate` — **`AsTarget` adapter becomes unnecessary and can be removed**:

```rescript
// Before (with adapter):
module Target = AsTarget.Make(RecordProductDemand)

// After (direct assignment):
module Delegate = RecordProductDemand
```

**Files affected**: `ExtensionMapping.res`, `ExtensionPointMapping.res` (Impl type + Make functor), `Extension_Builder.res`, `ExtensionPoint_Builder.res`, `Extension_Operations.res`, `ExtensionPoint_Operations.res`, Platform implementations, `StateChangeSlice.res` (spec), `StateChangeSlice_Callback.res`, `Dcb_Builder.res`, `DcbEventLog.res`, `DcbValidation.res`, all mapping and StateChangeSlice spec files in examples, test fixtures.

### Phase 10: Single-argument `Make` + composable EP mappings + implicit naming — EXTRACTED

Extracted to separate plan: `single-arg-make-and-composable-ep-mappings.md`

### Breaking Changes

Phases 2-3 are breaking changes to `Platform.T` (`feat!:`). All Platform implementations (Platform.T type, AWS Platform, InMemory Platform) are updated atomically. Example plugins in this monorepo are updated in the same commit. External consumers (private-consumer-repo) need updating.

Phases 8-10 are additional breaking changes (`feat!:`). Phase 9 (`producedEvent` → `event`) affects all StateChangeSlice specs.

---

## Risk

- **ReScript functor limitations**: Simplifying module type signatures may hit constraints around first-class modules in functor args. Prototype before committing to an approach.
- **moduleUrl dependency**: Lambda bundling relies on `import.meta.url` for module resolution. Any approach that moves or generates this needs careful testing with the actual AWS deployment.
- **Multi-mapping edge cases**: Some components may have multiple mappings. The simplified API must handle both single and multi-mapping cases without regressing ergonomics.
