---
title: Aggregate-Based Implementation
sidebar_position: 2
---

# Aggregate-Based Implementation

The aggregate-based approach uses a **separate event log per aggregate instance**. Each entity in the domain is modelled as an aggregate with its own stream of events. Commands are processed by loading the aggregate's event history, running business logic, and appending new events to that aggregate's log.

This is the traditional event sourcing pattern and the starting point for most Reventless applications.

---

## Plugin 1: Catalog

Manages the product catalogue — what is available for sale and how it is organized.

### Aggregate: `Product`

A product listing with name, description, and price.

| Commands | Events |
|---|---|
| `AddProduct` | `ProductAdded` |
| `UpdateProductName` | `ProductNameUpdated` |
| `UpdateProductDescription` | `ProductDescriptionUpdated` |
| `UpdateProductPrice` | `ProductPriceUpdated` |

### Aggregate: `Category`

A named grouping of products (e.g. "Books", "Electronics"). `Product` aggregates reference a `CategoryId`.

| Commands | Events |
|---|---|
| `AddCategory` | `CategoryAdded` |
| `RenameCategory` | `CategoryRenamed` |
| `ArchiveCategory` | `CategoryArchived` |

---

## Plugin 2: Ordering

Handles the purchase flow — who is buying and what they ordered.

### Aggregate: `Customer`

A registered buyer with contact details and account status.

| Commands | Events |
|---|---|
| `RegisterCustomer` | `CustomerRegistered` |
| `UpdateEmail` | `EmailUpdated` |
| `UpdateAddress` | `AddressUpdated` |
| `DeactivateCustomer` | `CustomerDeactivated` |

### Aggregate: `Order`

A confirmed purchase referencing `Product` IDs and a `CustomerId`. Clear, linear lifecycle.

| Commands | Events |
|---|---|
| `PlaceOrder` | `OrderPlaced` |
| `ShipOrder` | `OrderShipped` |
| `CancelOrder` | `OrderCancelled` |

---

## Cross-Plugin Integration

`Order` references products by `ProductId` — integration by ID, not by object. This demonstrates the standard event-sourcing pattern for cross-plugin references without tight coupling between Plugins.

---

## Implementation

The following walkthrough uses the **Catalog** Plugin from `examples/aggregate/catalog/` — the `Product` aggregate with its read model and the `CatalogPlugin` that wires everything together.

### 1. Aggregate Spec

The spec module defines the vocabulary for the aggregate: its commands, the events it can emit, and the errors it can return.

```rescript
// Product.res

module Id = ReventlessSpec.Id.String

let name = "Product"

@schema
type command =
  | AddProduct({productId: string, name: string, description: string, price: float})
  | UpdateProductName({productId: string, name: string})
  | UpdateProductDescription({productId: string, description: string})
  | UpdateProductPrice({productId: string, price: float})

@schema
type event =
  | ProductAdded({productId: string, name: string, description: string, price: float})
  | ProductNameUpdated({productId: string, name: string})
  | ProductDescriptionUpdated({productId: string, description: string})
  | ProductPriceUpdated({productId: string, price: float})

@schema
type error =
  | ProductAlreadyExists
  | ProductNotFound
```

The `@schema` attribute generates JSON serialization automatically via the Sury PPX — no hand-written encoders or decoders needed.

### 2. Behavior

The behavior module implements the aggregate's state machine. It defines the in-memory state type and provides four functions that the framework calls at runtime:

| Function | Called when |
|---|---|
| `init` | The first event is replayed (aggregate does not yet exist) |
| `apply` | Subsequent events are replayed to rebuild state |
| `create` | A command arrives for an aggregate that does not yet exist |
| `execute` | A command arrives for an aggregate that already exists |

```rescript
// ProductBehavior.res

open Product

module Spec = Product

@schema
type state = {name: string, description: string, price: float}

let resolverConfig = {
  ReventlessSpec.Behavior.commandSchema,
  fields: [],
}

let init = event =>
  switch event {
  | ProductAdded({name, description, price}) => {name, description, price}
  | ProductNameUpdated(_)
  | ProductDescriptionUpdated(_)
  | ProductPriceUpdated(_) =>
    throw(Reventless.Message.InvalidEvent(
      event->Reventless.Message.encode(eventSchema)
    ))
  }

let apply = (state, event) =>
  switch event {
  | ProductAdded({name, description, price}) => {name, description, price}
  | ProductNameUpdated({name})               => {...state, name}
  | ProductDescriptionUpdated({description}) => {...state, description}
  | ProductPriceUpdated({price})             => {...state, price}
  }

let create = (command, _context, errorHandler) =>
  switch command {
  | AddProduct({productId, name, description, price}) => [
      ProductAdded({productId, name, description, price}),
    ]
  | UpdateProductName(_)
  | UpdateProductDescription(_)
  | UpdateProductPrice(_) =>
    errorHandler(ProductNotFound, command, _context)
  }

let execute = (state, command, context, errorHandler) =>
  switch command {
  | AddProduct(_) =>
    errorHandler(ProductAlreadyExists, command, context)
  | UpdateProductName({name}) if name == state.name => []
  | UpdateProductName({productId, name}) =>
    [ProductNameUpdated({productId, name})]
  | UpdateProductDescription({description})
    if description == state.description => []
  | UpdateProductDescription({productId, description}) => [
      ProductDescriptionUpdated({productId, description}),
    ]
  | UpdateProductPrice({price}) if price == state.price => []
  | UpdateProductPrice({productId, price}) =>
    [ProductPriceUpdated({productId, price})]
  }
```

Update commands are idempotent: if the incoming value matches the current state the handler returns an empty event list, producing no write.

### 3. Read Model

The read model defines the query-side view and how aggregate events are projected into it.

```rescript
// ProductsReadModel.res

module Id = ReventlessSpec.Id.String

@schema
type state = {
  productId: string,
  name: string,
  description: string,
  price: float,
}

let name = "Products"
```

Projection mappings subscribe to aggregate events and translate them to `Set` or `Update` instructions on the read model store:

```rescript
// ProductsProjections.res

open ReventlessSpec
open ReventlessSpec.Projection
open Reventless.Projection

module ProductMapping = Mapping.Make(
  Product,
  ProductsReadModel,
  {
    let map = ({Message.event: event, id, _}) =>
      switch event {
      | Product.ProductAdded({productId, name, description, price}) =>
        Projection.Set(id, {
          ProductsReadModel.productId,
          name,
          description,
          price,
        })
      | Product.ProductNameUpdated({name}) =>
        Update(id, state => {...state, name})
      | Product.ProductDescriptionUpdated({description}) =>
        Update(id, state => {...state, description})
      | Product.ProductPriceUpdated({price}) =>
        Update(id, state => {...state, price})
      }
  },
)

module Mappings = Mappings.Make(ProductsReadModel)

let mappings: array<module(Mappings.Mapping)> = [module(ProductMapping)]
```

### 4. Plugin

The plugin wires all aggregates and read models together using any `Platform` implementation (in-memory for tests, AWS for production). A single `CatalogPlugin` covers both the `Product` and `Category` aggregates:

```rescript
// CatalogPlugin.res

open ReventlessSpec
open ReventlessSpec.Projection
open Reventless.Projection

module Make = (Platform: Platform.T) => {
  module ProductAggregate = Platform.Aggregate.Make(
    Product,
    ProductBehavior,
    Reventless.NoEventMappings.Make(Product),
  )

  module CategoryAggregate = Platform.Aggregate.Make(
    Category,
    CategoryBehavior,
    Reventless.NoEventMappings.Make(Category),
  )

  module ProductMappings: Mappings with module Target := ProductsReadModel = {
    module ProductMappings = Mappings.Make(ProductsReadModel)
    module type Mapping = ProductMappings.Mapping
    let mappings = ProductsProjections.mappings
  }

  module ProductReadModel = Platform.ReadModel.Make(ProductsReadModel, ProductMappings)

  module CategoryMappings: Mappings with module Target := CategoriesReadModel = {
    module CategoryMappings = Mappings.Make(CategoriesReadModel)
    module type Mapping = CategoryMappings.Mapping
    let mappings = CategoriesProjections.mappings
  }

  module CategoryReadModel =
    Platform.ReadModel.Make(CategoriesReadModel, CategoryMappings)
}
```

Swapping `Platform` is the only change needed to move from an in-memory test environment to a full AWS deployment.
