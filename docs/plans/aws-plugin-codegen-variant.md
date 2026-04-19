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

## Out of Scope

- `StateViewSliceStream` adoption (open question in analysis — separate decision)
- EventMappings support for AWS aggregates (no business use case yet)
- Tasks in AWS variant (no bundled Lambda task builder exists)
