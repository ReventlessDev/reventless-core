# Single-Argument Make + Composable EP Mappings

## Status: DONE — Parts A+B+C complete; Part D replaced by `extension-plugin-naming-and-auto-merge.md`

## Goal

Further simplify Extension/EP wiring to single-argument `Make` calls with implicit naming, and enable per-slice composable outgoing EP mappings that eliminate hand-written combined event types.

Extracted from Phase 10 of `reduce-app-developer-boilerplate.md`.

---

## Prerequisites

All done in `reduce-app-developer-boilerplate.md`:
- `module type Mapping` (renamed from `Impl`) with `module Delegate` field
- `producedEvent` → `event` in StateChangeSlice + `module Id = Id.String`
- `AsDelegate` removed — slices directly satisfy Delegate type
- `MakeMulti` variants available for full-control cases

---

## Part A: Single-Argument Extension.Make

**Current** (2 args):
```rescript
module OrdersExtensionMaker = Platform.Extension.Make(
  OrderingSpec.OrdersExtensionPoint,
  OrdersExtension.DemandMapping,
)
```

**Target** (1 arg):
```rescript
module OrdersExtensionMaker = Platform.Extension.Make(OrdersExtension.DemandMapping)
```

**How**: The `Mapping` module type retains `module ExtensionPoint` (reverses Phase 7 from the parent plan). `Make` extracts `Mapping.ExtensionPoint` as the Spec internally.

**Mapping module type change**:
```rescript
// ExtensionMapping.Mapping — module ExtensionPoint is NOT destructively substituted
module type Mapping = {
  module ExtensionPoint: Spec
  module Delegate: Reventless.Aggregate.Spec
  let mapIncomingEvent: ...
  let mapOutgoingEvent: ...
}
```

**Platform.T change**:
```rescript
module Extension: {
  module Make: (Mapping: ExtensionMapping.Mapping) => Extension.T
  module Make2: (Mapping1: ExtensionMapping.Mapping, Mapping2: ExtensionMapping.Mapping) => Extension.T
  module MakeMulti: (Spec: ExtensionMapping.Spec, Mappings: ExtensionMapping.Mappings with module Spec := Spec) => Extension.T
}
```

**Tradeoff**: Each mapping file needs `module ExtensionPoint = ...` (1 extra line per mapping), but plugin assembly is zero boilerplate.

**Impact on ExtensionMapping.Make functor**: Currently uses destructive substitution `Make(Spec, MappingImpl: Mapping with module ExtensionPoint := Spec)`. This would change to `Make(MappingImpl: Mapping)` and extract `Spec` from `MappingImpl.ExtensionPoint`.

**Files to change**:
- `reventless-infra/src/types/ExtensionMapping.res` — `Mapping` type keeps `module ExtensionPoint`, `Make` takes 1 arg
- `reventless-infra/src/types/Platform.res` — Extension.Make takes 1 arg
- `reventless-aws/src/Platform.res` — Update Extension.Make
- `reventless-in-memory/src/Platform.res` — Update Extension.Make
- All Extension mapping files in examples — add `module ExtensionPoint = Source` back
- All plugin files — simplify to 1-arg Make call

---

## Part B: Single-Argument ExtensionPoint.Make

**Current** (3 args):
```rescript
module ProductsEPMaker = Platform.ExtensionPoint.Make(
  CatalogSpec.ProductsExtensionPoint,
  ProductsExtensionPointMapping,
  {let moduleUrl: string = %raw(`import.meta.url`)},
)
```

**Target** (2 args — Mapping + Config):
```rescript
module ProductsEPMaker = Platform.ExtensionPoint.Make(
  ProductsExtensionPointMapping,
  {let moduleUrl: string = %raw(`import.meta.url`)},
)
```

Same principle — `Mapping` retains `module ExtensionPoint`, `Make` extracts it. The `Config` with `moduleUrl` is still needed for AWS Lambda bundling.

**Platform.T change**:
```rescript
module ExtensionPoint: {
  module Make: (
    Mapping: ExtensionPointMapping.Mapping,
    Config: {let moduleUrl: string},
  ) => ExtensionPoint.T
  module Make2: (
    Mapping1: ExtensionPointMapping.Mapping,
    Mapping2: ExtensionPointMapping.Mapping,
    Config: {let moduleUrl: string},
  ) => ExtensionPoint.T
  module MakeMulti: (
    Spec: ExtensionPointMapping.Spec,
    Mappings: ExtensionPoint.Mappings with module Spec := Spec,
  ) => ExtensionPoint.T
}
```

**Files to change**:
- `reventless-infra/src/types/ExtensionPointMapping.res` — `Mapping` type keeps `module ExtensionPoint`, `Make` takes 1 arg
- `reventless-infra/src/types/Platform.res` — ExtensionPoint.Make takes Mapping + Config
- Both Platform implementations
- All EP mapping files in examples — already have `module ExtensionPoint = ...`
- All plugin files — simplify to 2-arg Make call

---

## Part C: Composable Per-Slice Outgoing EP Mappings

**Problem**: In DCB, outgoing EP mappings require a hand-written `Delegate` module with a curated event type combining events from multiple slices. This is tedious and error-prone.

**Solution**: Each slice provides its own EP mapping. `Make2`/`Make3` merge them internally:

```rescript
// Per-slice — each only knows its own event type:
module AddProductEPMapping = {
  module ExtensionPoint = CatalogSpec.ProductsExtensionPoint
  module Delegate = AddProduct  // direct — has @schema type event
  let mapIncomingCommand = (_id, _command, _meta) => []
  let mapOutgoingEvent = Some((id, event, _meta, _queryEngine) =>
    switch event {
    | ProductAdded({productId, name, price}) => [
        PublishEvent(productId, ProductBecameAvailable({productId, name, price})),
      ]
    }
  )
}

module ChangeProductPriceEPMapping = {
  module ExtensionPoint = CatalogSpec.ProductsExtensionPoint
  module Delegate = ChangeProductPrice
  let mapIncomingCommand = (_id, _command, _meta) => []
  let mapOutgoingEvent = Some((id, event, _meta, _queryEngine) =>
    switch event {
    | ProductPriceChanged({productId, price}) => [
        PublishEvent(productId, ProductPriceChanged({productId, price})),
      ]
    }
  )
}

// EP Make2 merges them:
module ProductsEP = Platform.ExtensionPoint.Make2(
  AddProductEPMapping,
  ChangeProductPriceEPMapping,
  {let moduleUrl: string = %raw(`import.meta.url`)},
)
```

**Runtime behavior**:
1. Receives a JSON event from the DcbEventLog EventTopic
2. Tries decoding against each mapping's `Delegate.eventSchema`
3. On successful decode, calls that mapping's `mapOutgoingEvent`
4. Publishes resulting EP events

**Framework changes**:
- `ExtensionPointMapping.Make` compiles each mapping independently — each produces its own `mapOutgoingEvent` with its own decoder
- `ExtensionPoint_Builder` / `ExtensionPoint_Operations` iterate over all mappings' `mapOutgoingEvent` for each incoming event
- This is already how the `mappings: array<module(Mapping)>` array works — each mapping has its own `mapOutgoingEvent: option<...>`. The only change is that each mapping decodes against a different `Delegate.eventSchema` (currently they all share the same Delegate)

**Note**: For aggregate-based examples, a single mapping per aggregate is already the pattern (one `ProductMapping` per `Product` aggregate). This change primarily benefits DCB, where the combined event type was necessary.

---

## Part D: Implicit Naming

Extension/EP component names are derived automatically:
- Single mapping: `EP.name ++ "." ++ Delegate.name` (e.g., `"Ordering.Orders.ProductDemand"`)
- Multi mapping (`Make2`): `EP.name ++ "." ++ Delegate1.name ++ "+" ++ Delegate2.name`

Custom names only via `MakeMulti` (full Mappings container).

---

## Sequencing

1. **Parts A+B** (single-arg Make): Can be done together — mechanical change to Platform.T + implementations + examples
2. **Part C** (composable EP mappings): Deeper change to EP runtime, should be done separately
3. **Part D** (implicit naming): Falls out naturally from Parts A+B

---

## Risk

- **Reversing Phase 7**: Re-adding `module ExtensionPoint` to mapping files adds 1 line per file. But it enables zero-boilerplate plugin assembly, which is where the real DX improvement is.
- **Per-slice EP mapping runtime**: The try-decode-against-each-schema approach has a performance cost proportional to the number of mappings. For typical plugins (2-5 slices), this is negligible.
- **`Make2`/`Make3` proliferation**: ReScript functors can't take arrays of modules, so we need numbered variants. In practice, 2-3 mappings per EP covers most cases. `MakeMulti` with full Mappings container handles the rest.
- **Pulumi state**: Implicit naming changes component names, potentially triggering resource recreation in existing deployments. `MakeMulti` preserves backward compatibility for deployed systems.
