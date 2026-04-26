// AUTO-GENERATED — do not edit. Run `npm run generate` to update.
open Reventless.Projection

module Make = (Platform: ReventlessInfra.Platform.T) => {
  // Aggregates
  module CatalogProductAggregate = Platform.Aggregate.Make(
    CatalogProduct,
    CatalogProductBehavior,
    ReventlessInfra.NoEventMappings.Make(CatalogProduct),
  )
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

  // ReadModels
  @reventless.projections
  module AvailableProductsProjectionsWrapper: Mappings with module Target := AvailableProductsReadModel = {
    let mappings: array<module(Mapping)> = [module(AvailableProductsProjections.CatalogProductMapping)]
  }
  module AvailableProductsReadModelMaker = Platform.ReadModel.Make(AvailableProductsReadModel, AvailableProductsProjectionsWrapper)
  @reventless.projections
  module CustomersProjectionsWrapper: Mappings with module Target := CustomersReadModel = {
    let mappings: array<module(Mapping)> = [module(CustomersProjections.CustomerMapping)]
  }
  module CustomersReadModelMaker = Platform.ReadModel.Make(CustomersReadModel, CustomersProjectionsWrapper)
  @reventless.projections
  module OrdersProjectionsWrapper: Mappings with module Target := OrdersReadModel = {
    let mappings: array<module(Mapping)> = [module(OrdersProjections.OrderMapping)]
  }
  module OrdersReadModelMaker = Platform.ReadModel.Make(OrdersReadModel, OrdersProjectionsWrapper)

  // Tasks
  module OrderNotificationsTask = Platform.Task.Make(OrderNotifications)

  // ExtensionPoints
  module OrdersExtensionPointMaker = Platform.ExtensionPoint.Make(OrdersExtensionPointMapping)

  // Extensions
  module ProductsExtensionMaker = Platform.Extension.Make(ProductsExtension.Mapping)

  let pluginStructure = Platform.Plugin.makePluginDefinition(
    ~name="Ordering",
    ~aggregates=[module(CatalogProductAggregate), module(CustomerAggregate), module(OrderAggregate)],
    ~readModels=[module(AvailableProductsReadModelMaker), module(CustomersReadModelMaker), module(OrdersReadModelMaker)],
    ~extensions=[module(ProductsExtensionMaker)],
  )

  let make = (~uiBundleUrl=?) =>
    Platform.Plugin.make(
      ~name="Ordering",
      ~heartbeatInterval=60,
      ~extensionPoints=[module(OrdersExtensionPointMaker)],
      ~extensions=[module(ProductsExtensionMaker)],
      ~aggregates=[module(CatalogProductAggregate), module(CustomerAggregate), module(OrderAggregate)],
      ~readModels=[module(AvailableProductsReadModelMaker), module(CustomersReadModelMaker), module(OrdersReadModelMaker)],
      ~tasks=[module(OrderNotificationsTask)],
      ~pluginStructure=pluginStructure,
      ~uiFragments=?uiBundleUrl->Option.map(url =>
        Platform.Plugin.makeAutoUIManifest(
          ~remoteEntryUrl=url,
          ~name="Ordering",
          ~aggregates=[module(CatalogProductAggregate), module(CustomerAggregate), module(OrderAggregate)],
          ~readModels=[module(AvailableProductsReadModelMaker), module(CustomersReadModelMaker), module(OrdersReadModelMaker)],
          ~readModelPositions=["platform-summary"],
          ~aggregatePositions=["resource-detail"],
        )
      ),
    )
}
