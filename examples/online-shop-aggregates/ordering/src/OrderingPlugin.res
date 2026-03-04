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
    ReventlessInfra.NoEventMappings.Make(Order),
  )

  module CustomerProjections: Projection.Mappings with module Target := CustomersReadModel = {
    module M = Projection.Mappings.Make(CustomersReadModel)
    module type Mapping = M.Mapping
    let mappings: array<module(Mapping)> = [module(CustomersProjections.CustomerMapping)]
  }

  module CustomerReadModel = Platform.ReadModel.Make(CustomersReadModel, CustomerProjections)

  module OrderProjections: Projection.Mappings with module Target := OrdersReadModel = {
    module M = Projection.Mappings.Make(OrdersReadModel)
    module type Mapping = M.Mapping
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
    let mappings: array<module(Mapping)> = [
      module(AvailableProductsProjections.CatalogProductMapping),
    ]
  }

  module AvailableProductsReadModelMaker = Platform.ReadModel.Make(
    AvailableProductsReadModel,
    AvailableProductProjections,
  )

  // Build the Products extension (subscribing to Catalog's EP)
  module ProductsProductMapping = ReventlessInfra.ExtensionMapping.Make(
    CatalogSpec.ProductsExtensionPoint,
    ProductsExtension.ProductMapping,
  )
  module ProductsExtensionMappings: ReventlessInfra.ExtensionMapping.Mappings
    with module Spec := CatalogSpec.ProductsExtensionPoint = {
    module type Mapping = ReventlessInfra.ExtensionMapping.T
      with module ExtensionPoint := CatalogSpec.ProductsExtensionPoint
    let name = "OrderingProducts"
    let mappings: array<module(Mapping)> = [module(ProductsProductMapping)]
  }
  module ProductsExtensionMaker = Platform.Extension.Make(
    CatalogSpec.ProductsExtensionPoint,
    ProductsExtensionMappings,
  )

  // Compile the Orders extension point mappings, then build the EP component
  module OrdersEPOrderMapping = ReventlessInfra.ExtensionPointMapping.Make(
    OrderingSpec.OrdersExtensionPoint,
    OrdersExtensionPoint.OrderMapping,
  )
  module OrdersEPMappings = {
    module Spec = OrderingSpec.OrdersExtensionPoint
    module type Mapping = ReventlessInfra.ExtensionPointMapping.T with module ExtensionPoint := Spec
    let mappings: array<module(Mapping)> = [module(OrdersEPOrderMapping)]
  }
  module OrdersExtensionPointMaker = Platform.ExtensionPoint.Make(
    OrderingSpec.OrdersExtensionPoint,
    OrdersEPMappings,
  )

  // --- Self-assembly: produce a ready-to-use Plugin.component ---

  let make = (
    ~scheduler: Pulumi.Output.t<ReventlessInfra.Scheduler.operations>,
    ~api: Platform.api,
    ~apiRole: Platform.role,
  ) =>
    Platform.Plugin.make(
      ~name="Ordering",
      ~version="1.0.0",
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
      ~api,
      ~apiRole,
      ~scheduler,
    )
}
