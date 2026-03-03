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

  module CustomerMappings: Projection.Mappings with module Target := CustomersReadModel = {
    module CustomerMappings = Projection.Mappings.Make(CustomersReadModel)
    module type Mapping = CustomerMappings.Mapping
    let mappings = CustomersProjections.mappings
  }

  module CustomerReadModel = Platform.ReadModel.Make(CustomersReadModel, CustomerMappings)

  module OrderMappings: Projection.Mappings with module Target := OrdersReadModel = {
    module OrderMappings = Projection.Mappings.Make(OrdersReadModel)
    module type Mapping = OrderMappings.Mapping
    let mappings = OrdersProjections.mappings
  }

  module OrderReadModel = Platform.ReadModel.Make(OrdersReadModel, OrderMappings)

  // Catalog product shadow — driven by Catalog's ProductsExtensionPoint
  module CatalogProductAggregate = Platform.Aggregate.Make(
    CatalogProduct,
    CatalogProductBehavior,
    ReventlessInfra.NoEventMappings.Make(CatalogProduct),
  )

  module AvailableProductsMappings: Projection.Mappings with module Target := AvailableProductsReadModel = {
    module AvailableProductsMappings = Projection.Mappings.Make(AvailableProductsReadModel)
    module type Mapping = AvailableProductsMappings.Mapping
    let mappings = AvailableProductsProjections.mappings
  }

  module AvailableProductsReadModelMaker = Platform.ReadModel.Make(
    AvailableProductsReadModel,
    AvailableProductsMappings,
  )

  // Build the Products extension (subscribing to Catalog's EP)
  module ProductsExtensionMaker = Platform.Extension.Make(
    ProductsExtensionPointSpec,
    ProductsExtension.Mappings,
  )

  // Compile the Orders extension point mapping, then build the EP component
  module OrdersEPMappingT = ReventlessInfra.ExtensionPointMapping.Make(
    OrdersExtensionPointSpec,
    OrdersExtensionPointMapping,
  )
  module OrdersEPMappings = {
    module Spec = OrdersExtensionPointSpec
    module type Mapping = ReventlessInfra.ExtensionPointMapping.T with module ExtensionPoint := Spec
    let mappings: array<module(Mapping)> = [module(OrdersEPMappingT)]
  }
  module OrdersExtensionPointMaker = Platform.ExtensionPoint.Make(
    OrdersExtensionPointSpec,
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
