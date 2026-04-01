# ReScript Module System

## Module Types (Signatures)

Define the shape a module must have:

```rescript
module type Printable = {
  type t
  let toString: t => string
}
```

## Module Constraints

Constrain a module to a type — **hides values not in the type**:

```rescript
module MyModule: Printable = {
  type t = string
  let toString = s => s
  let helper = () => "hidden"  // warning 32: unused (not in Printable)
}
```

**Important:** Module sealing kills type identity from outside. `MyModule.t` becomes abstract — external code cannot construct values of type `MyModule.t` directly.

**Rule:** Do NOT annotate spec modules with type constraints (e.g., `: StateChangeSlice.Spec`) when passing them to functors. Leave annotations off and let the functor check structural compatibility at the call site.

## Functors (Module Functions)

Create modules parameterized by other modules:

```rescript
module type Config = {
  let baseUrl: string
}

module MakeClient = (C: Config) => {
  let fetch = async (path: string) => {
    await Http.get(C.baseUrl ++ path)
  }
}

// Usage
module ProdClient = MakeClient({
  let baseUrl = "https://api.example.com"
})
```

## First-Class Modules

Pack modules as values, pass them around:

```rescript
module type T = {
  let name: string
  let make: unit => component
}

// Pack a module into a value
let packed: module(T) = module(MyImplementation)

// Unpack a module from a value
let module(M) = packed
M.make()

// In arrays
let plugins: array<module(T)> = [
  module(PluginA),
  module(PluginB),
]
```

## Module Type with Refinement

Refine abstract types when constraining a module:

```rescript
module type Base = {
  module Spec: SomeSpec
  let make: unit => unit
}

// Refine Spec to a specific module
module M: Base with module Spec = MySpec = {
  module Spec = MySpec
  let make = () => ()
}
```

## Reventless Functor Pattern

All Reventless components follow this pattern:

```rescript
// Platform provides builders as functors
module Make = (Platform: ReventlessInfra.Platform.T) => {
  // Build components by applying functors
  module ProductAggregate = Platform.Aggregate.Make(
    Product,           // Spec module
    ProductBehavior,   // Behavior module
    ReventlessInfra.NoEventMappings.Make(Product)  // Event mappings
  )

  // Compose into plugin
  let make = (~scheduler, ~api, ~apiRole) =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~aggregates=[module(ProductAggregate)],
      ...
    )
}
```

## Namespace Convention

Packages use `rescript.json` namespace to avoid collisions:

| Package Type | Namespace | Example |
|-------------|-----------|---------|
| Spec package | `<Plugin>Spec` | `CatalogSpec` |
| Plugin package | `<Plugin>Plugin` | `CatalogPlugin` |
| Platform package | `true` (auto) | Uses package name |

**Warning:** Never use bare names that might shadow `RescriptCore` modules (e.g., don't name a package namespace `Array` or `String`).

## Double Namespace for Plugin Composition

When composing plugins in the platform, the module path has a double namespace:

```rescript
// PackageNamespace.ModuleName.Make(Platform)
module Catalog = CatalogPlugin.CatalogPlugin.Make(Platform)
```

This is because the package namespace (`CatalogPlugin`) wraps the module name (`CatalogPlugin`) which contains the `Make` functor.

## Open Statements

```rescript
// File-level open (use sparingly)
open ReventlessSpec

// Avoid opening modules that shadow common names
// BAD: open ReventlessCore  (inside reventless-core tests — redundant, causes shadow warnings)

// Suppress shadow warnings when open is intentional
@@warning("-44")
```

**Gotcha:** `open ReventlessCore` inside reventless-core test files is redundant (the package is already in the `ReventlessCore` namespace). It causes warning 44 (shadows). Remove it.
