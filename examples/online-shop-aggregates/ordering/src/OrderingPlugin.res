// Ordering plugin — platform-agnostic composition root.
// Wires the Customer and Order aggregates and their read models,
// the OrdersExtensionPoint (outbound), and the ProductsExtension (inbound).

open Reventless

module Make = (Platform: ReventlessInfra.Platform.T) => {
  module CustomerAggregate = Platform.Aggregate.Make(
    Customer,
    CustomerBehavior,
    ReventlessInfra.NoEventMappings.Make(Customer),
  )

  module OrderAggregate = Platform.Aggregate.Make(
    Order,
    OrderBehavior,
    Order_EventMappings,
  )

  module CustomerProjections: Projection.Mappings with module Target := CustomersReadModel = {
    module M = Projection.Mappings.Make(CustomersReadModel)
    module type Mapping = M.Mapping
    let moduleUrl: string = %raw(`import.meta.url`)
    let mappings: array<module(Mapping)> = [module(CustomersProjections.CustomerMapping)]
  }

  module CustomerReadModel = Platform.ReadModel.Make(CustomersReadModel, CustomerProjections)

  module OrderProjections: Projection.Mappings with module Target := OrdersReadModel = {
    module M = Projection.Mappings.Make(OrdersReadModel)
    module type Mapping = M.Mapping
    let moduleUrl: string = %raw(`import.meta.url`)
    let mappings: array<module(Mapping)> = [module(OrdersProjections.OrderMapping)]
  }

  module OrderReadModel = Platform.ReadModel.Make(OrdersReadModel, OrderProjections)

  // Catalog product shadow — driven by Catalog's ProductsExtensionPoint
  module CatalogProductAggregate = Platform.Aggregate.Make(
    CatalogProduct,
    CatalogProductBehavior,
    ReventlessInfra.NoEventMappings.Make(CatalogProduct),
  )

  module AvailableProductProjections: Projection.Mappings
    with module Target := AvailableProductsReadModel = {
    module M = Projection.Mappings.Make(AvailableProductsReadModel)
    module type Mapping = M.Mapping
    let moduleUrl: string = %raw(`import.meta.url`)
    let mappings: array<module(Mapping)> = [
      module(AvailableProductsProjections.CatalogProductMapping),
    ]
  }

  module AvailableProductsReadModelMaker = Platform.ReadModel.Make(
    AvailableProductsReadModel,
    AvailableProductProjections,
  )

  // Build the Products extension (subscribing to Catalog's EP)
  module ProductsExtensionMaker = Platform.Extension.Make(
    ProductsExtension.ProductMapping,
  )

  // Build the Orders extension point component
  module OrdersExtensionPointMaker = Platform.ExtensionPoint.Make(
    OrdersExtensionPoint.OrderMapping,
    {let moduleUrl: string = %raw(`import.meta.url`)},
  )

  module OrderNotificationsTask = Platform.Task.Make(OrderNotifications)

  // --- Self-assembly: produce a ready-to-use Plugin.component ---

  let make = () =>
    Platform.Plugin.make(
      ~name="Ordering",
      ~heartbeatInterval=60,
      ~aggregates=[
        module(CustomerAggregate),
        module(OrderAggregate),
        module(CatalogProductAggregate),
      ],
      ~readModels=[
        module(CustomerReadModel),
        module(OrderReadModel),
        module(AvailableProductsReadModelMaker),
      ],
      ~extensionPoints=[module(OrdersExtensionPointMaker)],
      ~extensions=[module(ProductsExtensionMaker)],
      ~tasks=[module(OrderNotificationsTask)],
    )
}
