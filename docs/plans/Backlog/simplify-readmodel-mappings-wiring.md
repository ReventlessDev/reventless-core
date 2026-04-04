# Simplify ReadModel Mappings Wiring

## Status: BACKLOG

## Goal

Reduce ReadModel projection wiring from 6 lines to 4 lines per ReadModel in plugin files.

---

## Problem

Every ReadModel in a plugin requires a Mappings wrapper module with boilerplate:

```rescript
// Current (6 lines):
module ProductProjections: Mappings with module Target := ProductsReadModel = {
  module M = Mappings.Make(ProductsReadModel)
  module type Mapping = M.Mapping
  let moduleUrl: string = %raw(`import.meta.url`)
  let mappings: array<module(Mapping)> = [module(ProductsProjections.ProductMapping)]
}
module ProductReadModel = Platform.ReadModel.Make(ProductsReadModel, ProductProjections)
```

The app developer just wants: "ProductsReadModel is projected from ProductMapping".

**Ideal**:
```rescript
module ProductReadModel = Platform.ReadModel.Make(ProductsReadModel, {
  let moduleUrl: string = %raw(`import.meta.url`)
  let mappings = [module(ProductsProjections.ProductMapping)]
})
```

---

## Prior Art

This was Phase 4 of `reduce-app-developer-boilerplate.md`. It was prototyped and deferred.

### What was tried

Changed `Platform.T` ReadModel.Make to accept a simplified `MappingsConfig`:

```rescript
module ReadModel: {
  module Make: (
    Spec: Reventless.ReadModel.Spec,
    MappingsConfig: {
      let moduleUrl: string
      let mappings: array<module(Reventless.Projection.Mapping with type targetState = Spec.state)>
    },
  ) => ReadModel.T with module Spec = Spec and type api = api and type role = role
}
```

The **framework code compiled**, but **app code failed**: ReScript cannot infer first-class module packing types from functor parameter context. When writing `let mappings = [module(SomeMapping)]` inside an anonymous functor argument, the compiler emits "The signature for this packaged module couldn't be inferred." The explicit `module type Mapping = M.Mapping` + type annotation on `mappings` is required by the language.

---

## Possible Approaches

### 1. Helper functor in `Projection.res`

Provide `Projection.BuildMappings` that inlines the `Mappings.Make` step:

```rescript
module ProductReadModel = Platform.ReadModel.Make(
  ProductsReadModel,
  Projection.BuildMappings(ProductsReadModel, {
    let moduleUrl: string = %raw(`import.meta.url`)
    let mappings = [module(ProductsProjections.ProductMapping)]
  }),
)
```

Still has the same type inference issue — `[module(X)]` inside the Config needs annotation. Would need prototyping.

### 2. PPX

A `@readModel` PPX attribute that generates the Mappings wrapper from a simpler annotation. Heavy — introduces a new PPX dependency.

### 3. ReScript language improvement

Request first-class module type inference from functor parameter context. Track upstream.

### 4. Explicit but shorter helper

A functor that takes the mapping modules individually (not as an array), avoiding the array packing issue:

```rescript
// Single source:
module ProductReadModel = Platform.ReadModel.MakeSingle(
  ProductsReadModel,
  ProductsProjections.ProductMapping,
  { let moduleUrl: string = %raw(`import.meta.url`) },
)

// Two sources:
module DemandReadModel = Platform.ReadModel.MakeDouble(
  ProductDemandReadModel,
  ProductDemandProjections.ProductMapping,
  ProductDemandProjections.ProductDemandMapping,
  { let moduleUrl: string = %raw(`import.meta.url`) },
)
```

This avoids the array issue entirely. Downside: need `MakeSingle`, `MakeDouble`, `MakeTriple` variants (but most read models have 1-2 sources).

---

## Files to investigate

| Area | Key files |
|------|-----------|
| Platform.T | `reventless-infra/src/types/Platform.res` |
| AWS Platform | `reventless-aws/src/Platform.res` |
| InMemory Platform | `reventless-in-memory/src/Platform.res` |
| Projection types | `reventless-spec/src/types/Projection.res` |
| Example plugins | `examples/online-shop-aggregates/*/src/*Plugin.res` |

---

## Risk

- **ReScript functor limitations**: First-class module arrays in functor args don't get type inference from context. Any approach must work around this.
- **Multi-source read models**: Some read models have 2+ projection sources (e.g., `ProductDemandReadModel` with `ProductMapping` + `ProductDemandMapping`). The solution must handle these.
