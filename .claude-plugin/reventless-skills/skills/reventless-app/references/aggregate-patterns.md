# Aggregate Architecture — Code Templates

## Aggregate Spec (e.g., Product.res)

```rescript
open Reventless
module Id = Id.String

let name = "Product"

@schema
type command =
  | Add({name: string, description: string, price: float})
  | UpdateName({name: string})
  | UpdatePrice({price: float})

@schema
type event =
  | Added({name: string, description: string, price: float})
  | NameUpdated({name: string})
  | PriceUpdated({price: float})

@schema
type error =
  | ProductAlreadyExists
  | ProductNotFound

let moduleUrl: string = %raw(`import.meta.url`)
```

## Behavior (e.g., ProductBehavior.res)

```rescript
open Product

module Spec = Product

@schema
type state =
  | NotCreated
  | Created({name: string, description: string, price: float})

let moduleUrl: string = %raw(`import.meta.url`)
let initialState = NotCreated

let evolve = (state, event) =>
  switch (state, event) {
  | (NotCreated, Added({name, description, price})) =>
    Created({name, description, price})
  | (Created(_), Added({name, description, price})) =>
    Created({name, description, price})
  | (Created(s), NameUpdated({name})) => Created({...s, name})
  | (Created(s), PriceUpdated({price})) => Created({...s, price})
  | (NotCreated, _) => state
  }

let decide = (state, command) =>
  switch (state, command) {
  | (NotCreated, Add({name, description, price})) =>
    Ok([Added({name, description, price})])
  | (NotCreated, _) => Error(ProductNotFound)
  | (Created(_), Add(_)) => Error(ProductAlreadyExists)
  | (Created(s), UpdateName({name})) if name == s.name => Ok([])
  | (Created(_), UpdateName({name})) => Ok([NameUpdated({name: name})])
  | (Created(s), UpdatePrice({price})) if price == s.price => Ok([])
  | (Created(_), UpdatePrice({price})) => Ok([PriceUpdated({price: price})])
  }
```

## ReadModel Spec (e.g., ProductsReadModel.res)

```rescript
open Reventless
module Id = Id.String

@schema
type state = {
  name: string,
  description: string,
  price: float,
}

let name = "Products"
let moduleUrl: string = %raw(`import.meta.url`)

open Reventless.ReadModel
let config = config()
let subIdConfig = None
```

## Projection (e.g., ProductsProjections.res)

```rescript
open Reventless.Message
open Reventless.Projection

module ProductMapping = Mapping.Make(
  Product,
  ProductsReadModel,
  {
    open Product
    let project = ({event, id, _}) =>
      switch event {
      | Added({name, description, price}) =>
        Set(id, {ProductsReadModel.name: name, description, price})
      | NameUpdated({name}) => Update(id, state => {...state, name})
      | PriceUpdated({price}) => Update(id, state => {...state, price})
      }
  },
)
```

## Plugin Composition (e.g., CatalogPlugin.res)

```rescript
open Reventless.Projection

module Make = (Platform: ReventlessInfra.Platform.T) => {
  // 1. Build aggregates
  module ProductAggregate = Platform.Aggregate.Make(
    Product,
    ProductBehavior,
    ReventlessInfra.NoEventMappings.Make(Product),
  )

  // 2. Wire projections
  module ProductProjections: Mappings with module Target := ProductsReadModel = {
    module M = Mappings.Make(ProductsReadModel)
    module type Mapping = M.Mapping
    let moduleUrl: string = %raw(`import.meta.url`)
    let mappings: array<module(Mapping)> = [
      module(ProductsProjections.ProductMapping),
    ]
  }

  // 3. Build read models
  module ProductReadModel = Platform.ReadModel.Make(
    ProductsReadModel,
    ProductProjections,
  )

  // 4. Self-assembly
  let make = (~scheduler, ~api, ~apiRole) =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~heartbeatInterval=60,
      ~aggregates=[module(ProductAggregate)],
      ~readModels=[module(ProductReadModel)],
      ~api,
      ~apiRole,
      ~scheduler,
    )
}
```

## Platform Main.res

```rescript
module Platform = ReventlessInMemory.Platform.Make()

module Catalog = CatalogPlugin.CatalogPlugin.Make(Platform)
module Ordering = OrderingPlugin.OrderingPlugin.Make(Platform)

Platform.makePlatform(
  ~version=Reventless.PackageVersion.fromCwd(),
  ~plugins=[module(Catalog), module(Ordering)],
)
```

## Directory Structure

```
plugin-name/
├── package.json
├── rescript.json
├── src/
│   ├── Aggregate/
│   │   ├── EntityName.res          # Spec (commands, events, errors)
│   │   └── EntityNameBehavior.res  # State machine (evolve, decide)
│   ├── ReadModel/
│   │   ├── EntityNamesReadModel.res    # Read model spec
│   │   └── EntityNamesProjections.res  # Projection mappings
│   ├── ExtensionPoint/
│   │   └── EntityNamesExtensionPoint.res  # EP mapping
│   ├── Extension/
│   │   └── ExternalExtension.res   # Extension mapping
│   └── PluginNamePlugin.res        # Composition root
└── tests/
    ├── Aggregate/
    │   └── EntityNameBehaviorTest.res
    ├── ReadModel/
    │   └── EntityNamesProjectionTest.res
    └── E2E/
        └── EntityNameE2ETest.res
```
