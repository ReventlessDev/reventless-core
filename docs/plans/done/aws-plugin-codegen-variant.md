# Plan: AWS Codegen Variant for `generate-plugin`

**Status:** Not started

Add a `variant: "aws"` mode to `generate-plugin` that emits AWS-specific bundled builders instead of `Platform.*`. Enables auto-generating `CatalogPlugin_Aws.res` / `OrderingPlugin_Aws.res` style assembly files.

---

## The Cross-Namespace Problem

Standard plugins are scanned and generated in-place: `generate-plugin src/` discovers files in `Aggregate/`, `ReadModel/`, etc. and emits unqualified module names (`Category`, `CategoryBehavior`, `CategoriesReadModel`).

AWS assembly packages are wrappers: `catalog-aws` has no component files of its own — it imports everything from `@reventlessdev/online-shop-hybrid-catalog` (namespace `CatalogPlugin`). The generator must:

1. **Scan a different directory** — the source plugin's `src/`, not the AWS package's own `src/`
2. **Qualify all names** with the source namespace — emit `CatalogPlugin.Category`, not `Category`

### Proposed invocation

```json
// catalog-aws/package.json
{
  "scripts": {
    "generate": "generate-plugin --aws CatalogPlugin ../catalog/src/",
    "prebuild": "npm run generate"
  }
}
```

`--aws <Namespace>` activates AWS variant and provides the qualifying namespace. The source dir argument points to the source plugin's `src/`. The output file defaults to `src/<Namespace>Plugin_Aws.res` relative to the working directory (`src/CatalogPlugin_Aws.res`).

Alternatively via `plugin.json`:
```json
// catalog-aws/src/plugin.json
{
  "variant": "aws",
  "sourceNamespace": "CatalogPlugin",
  "sourceSrcDir": "../catalog/src/"
}
```

The CLI flag approach is simpler and avoids circular confusion (the plugin.json lives in the aws package's own src/).

---

## Changes Required

### 1. `Config.res` — Add variant + source namespace

```res
type variant = Standard | Aws({sourceNamespace: string})

type config = {
  name: string,
  heartbeatInterval: int,
  exclude: array<string>,
  variant: variant,
}
```

The `sourceNamespace` and `sourceSrcDir` are passed via CLI and folded into config before rendering.

### 2. `Codegen.res` — AWS render paths

When `config.variant = Aws({sourceNamespace})`, prefix every component reference with `sourceNamespace ++ "."`.

**Module Make signature** — add AWS platform constraint:
```res
// Standard:
"module Make = (Platform: ReventlessInfra.Platform.T) => {"

// AWS:
"module Make = ("
"  Platform: ReventlessInfra.Platform.T"
"    with type api = ReventlessAws.Types.AppSync.api"
"    and type role = ReventlessAws.Types.AppSync.role,"
") => {"
```

**`renderAggregates`** — replace `Platform.Aggregate.Make` with `ReventlessAws.Aggregate_Builder_Single.Make`:
```res
// Generated output (aws variant):
module CategoryAggregate = ReventlessAws.Aggregate_Builder_Single.Make(
  CatalogPlugin.Category,
  CatalogPlugin.CategoryBehavior,
  ReventlessInfra.NoEventMappings.Make(CatalogPlugin.Category),
)
```

**`renderReadModels`** — keep `@reventless.projections` wrapper, replace `Platform.ReadModel.Make` with `ReventlessAws.ReadModel_Builder_Single.Make`:
```res
// Generated output (aws variant):
@reventless.projections
module CategoriesProjectionsWrapper: Mappings with module Target := CatalogPlugin.CategoriesReadModel = {
  let mappings: array<module(Mapping)> = [module(CatalogPlugin.CategoriesProjections.CategoryMapping)]
}
module CategoriesReadModelMaker = ReventlessAws.ReadModel_Builder_Single.Make(
  CatalogPlugin.CategoriesReadModel,
  CategoriesProjectionsWrapper,
)
```

**`renderExtensionPoints`** — replace all counts with `ReventlessAws.ExtensionPoint_Builder.Make`. For a single mapping, the generated pattern matches the current business handwritten approach:
```res
// Generated output (aws variant, single mapping):
module ProductsEPMappingT = ReventlessInfra.ExtensionPointMapping.Make(
  CatalogPlugin.ProductsExtensionPointMapping,
)
module ProductsEPMappings = {
  module Spec = CatalogPlugin.ProductsExtensionPointMapping.ExtensionPoint
  module type Mapping = ReventlessInfra.ExtensionPointMapping.T with module ExtensionPoint := Spec
  let name = "ProductsEPMappings"
  let moduleUrl: string = %raw(`import.meta.url`)
  let mappings: array<module(Mapping)> = [module(ProductsEPMappingT)]
}
module ProductsExtensionPointMaker = ReventlessAws.ExtensionPoint_Builder.Make(
  ProductsEPMappings.Spec,
  ProductsEPMappings,
  { let publishToAggregatesQueueUrls = Dict.make() },
)
```

Multi-mapping EPs follow the same structure with additional `module(MappingT_N)` entries.

**`renderSlices`** — no change for `StateChangeSlice`, `AutomationSlice`, etc. (no AWS-specific variant). `StateViewSlice` is kept as `Platform.StateViewSlice.Make` unless `StateViewSliceStream` adoption is decided separately.

### 3. CLI entry point — `generate-plugin` binary

Add `--aws <Namespace>` flag parsing. When present:
- Override `srcDir` to the path argument (last positional)
- Set `config.variant = Aws({sourceNamespace: namespace})`
- Output file: `src/<Namespace>_Aws.res` relative to cwd, unless `--output` is specified

---

## Generated Header

The AWS generated file needs `open Reventless.Projection` (for `Mappings`) and the AWS module constraint. Because the source components come from a qualified namespace, no additional `open` is needed.

---

## Test: Core Examples

Once implemented, add `generate` + `prebuild` scripts and `src/plugin.json` (or use CLI flags) to the core's own `examples/online-shop-hybrid/catalog-aws/` and `examples/online-shop-hybrid/ordering-aws/`. The currently handwritten files become generated, which becomes the regression test.

---

## Previously Out of Scope — Now Planned

---

### Feature A: StateViewSliceStream adoption

`renderSlices` currently keeps `StateViewSlice` as `Platform.StateViewSlice.Make` in both standard and AWS variants. `Platform.StateViewSliceStream` already exists (wraps `StateViewSlice_Builder_Stream.Make`) — it differs by using `QueryDbStorage_DynamoDbStream`, which enables DynamoDB Streams and the `StateTopic_AppSync` push channel.

**Discovery** — `Discovery.res`: scan a `StateViewSliceStream/` sibling folder (same pattern as `StateViewSlice/`). Collected stems feed a new `stateViewSlicesStream: array<string>` field on `Pairing.resolved`.

**Pairing** — `Pairing.res`: add `stateViewSlicesStream: array<string>` to the `resolved` record and populate it from the new discovery result.

**Codegen** — `Codegen.res`: `renderSlicesAws` is already generic (`~platformFactory`, `~suffix`), so the render call is:
```res
renderSlicesAws(~platformFactory="StateViewSliceStream", ~suffix="StreamSlice", ~ns, resolved.stateViewSlicesStream)
```
Standard variant uses the same `renderSlices` helper:
```res
renderSlices(~platformFactory="StateViewSliceStream", ~suffix="StreamSlice", resolved.stateViewSlicesStream)
```

**Plugin.make assembly** — stream slices produce modules with suffix `StreamSlice` (e.g. `ProductsStreamSlice`). They satisfy the same `StateViewSlice.T` interface and must be merged into the existing `~stateViewSlices` array. Extend the `~stateViewSlices` `renderMakeParam` call (or add a second one) to append stream-suffix entries alongside regular `Slice` entries.

Generated output (AWS variant):
```res
// StateViewSliceStream
module ProductsStreamSlice = Platform.StateViewSliceStream.Make(CatalogPlugin.Products)
```
Passed to Plugin.make as: `~stateViewSlices=[module(RegularSlice), module(ProductsStreamSlice)]`

**No new CLI flag needed.** The folder name is the opt-in signal.

---

### Feature B: EventMappings for AWS aggregates

`renderAggregatesAws` hardcodes `ReventlessInfra.NoEventMappings.Make(Ns.Spec)`. The discovery and pairing already populate `aggregateDef.eventMappings: option<string>` for the standard variant — the AWS path just ignores it.

**Codegen.res** — single change in `renderAggregatesAws` (currently line 132):
```res
// Before:
"    ReventlessInfra.NoEventMappings.Make(" ++ ns ++ "." ++ spec ++ "),"

// After:
let mappingsExpr = eventMappings
  ->Option.map(m => ns ++ "." ++ m)
  ->Option.getOr("ReventlessInfra.NoEventMappings.Make(" ++ ns ++ "." ++ spec ++ ")")
"    " ++ mappingsExpr ++ ","
```

The destructure of `aggregateDef` in the same function needs `eventMappings` added alongside `spec` and `behavior`.

No other files change — discovery and pairing already do the right thing.

Generated output (AWS variant, with custom mappings):
```res
module OrderAggregate = ReventlessAws.Aggregate_Builder_Single.Make(
  OrderingPlugin.Order,
  OrderingPlugin.OrderBehavior,
  OrderingPlugin.Order_EventMappings,
)
```

---

### Feature C: Tasks in AWS variant

`ReventlessAws.Task_Builder` already exists (`reventless-aws/src/components/Task_Builder.res` → `include Task_Builder_PerBucket`). `Platform.Task.Make` (Platform.res line 414) also already wraps it with empty default Config. `renderTasksAws` exists but emits `Platform.Task.Make(Ns.Stem)` — inconsistent with the pattern used for aggregates, read models, and extension points, which all bypass Platform.* and use the explicit AWS builders directly.

**Codegen.res** — `renderTasksAws` keeps `Platform.Task.Make(Ns.Stem)`. Switching to `ReventlessAws.Task_Builder.Make` directly was attempted but fails because that builder requires `ReventlessCore.Task.Spec`, which is inaccessible from AWS assembly packages that only depend on `reventless-aws` (not `reventless-core` directly). `Platform.Task.Make` inside the platform functor body only requires `ReventlessInfra.Task.Spec`, which cross-package task modules do satisfy. No code change needed to `renderTasksAws`.

**Task spec files** must annotate `setup` parameters explicitly (not rely on polymorphic inference) so the compiled interface exports a concrete type. Example:
```res
let setup = (
  _queryEngine: Reventless.QueryEngine.operations,
  _queryBucketName: ReventlessInfra.Task.queryBucketName,
  _opts: Pulumi.ComponentResource.options,
): Reventless.Task.config => { ... }
```

**Verification** — `examples/online-shop-hybrid/catalog/src/Task/ImportProducts.res` added; `catalog-aws` regenerates and compiles clean. This is the regression test.
