// AUTO-GENERATED — do not edit. Run `npm run generate` to update.

@val external uiBundleUrl: option<string> = "process.env.ORDERING_UI_BUNDLE_URL"

module Make = (Platform: ReventlessInfra.Platform.T) => {
  // Aggregates
  module CatalogProductAggregate = Platform.Aggregate.Make(
    CatalogProduct,
    CatalogProduct_Behavior,
    ReventlessInfra.NoEventMappings.Make(CatalogProduct),
  )
  module CustomerAggregate = Platform.Aggregate.Make(
    Customer,
    Customer_Behavior,
    ReventlessInfra.NoEventMappings.Make(Customer),
  )
  module OrderAggregate = Platform.Aggregate.Make(
    Order,
    Order_Behavior,
    Order_Mappings,
  )

  // ReadModels
  module AvailableProductsReadModel = Platform.ReadModel.Make(AvailableProducts, AvailableProducts_Projections)
  module CustomersReadModel = Platform.ReadModel.Make(Customers, Customers_Projections)
  module OrdersReadModel = Platform.ReadModel.Make(Orders, Orders_Projections)

  // Tasks
  module OrderNotificationsTask = Platform.Task.Make(OrderNotifications)

  // ExtensionPoints
  module Orders_ExtensionPoint = Platform.ExtensionPoint.Make(Orders_ExtensionPointMapping)

  // Extensions
  module Products_Extension = Platform.Extension.Make(Products_Extension.Mapping)

  let pluginStructure = Platform.Plugin.makePluginDefinition(
    ~name="Ordering",
    ~aggregates=[module(CatalogProductAggregate), module(CustomerAggregate), module(OrderAggregate)],
    ~readModels=[module(AvailableProductsReadModel), module(CustomersReadModel), module(OrdersReadModel)],
    ~extensions=[module(Products_Extension)],
    ~extensionPoints=[module(Orders_ExtensionPointMapping)],
    ~componentChapters=Dict.fromArray([("AvailableProducts", "CatalogProduct"), ("CatalogProduct", "CatalogProduct"), ("Customer", "Customer"), ("Customers", "Customer"), ("Order", "Order"), ("Orders", "Order")]),
  )

  let make = () =>
    Platform.Plugin.make(
      ~name="Ordering",
      ~heartbeatInterval=5,
      ~extensionPoints=[module(Orders_ExtensionPoint)],
      ~extensions=[module(Products_Extension)],
      ~aggregates=[module(CatalogProductAggregate), module(CustomerAggregate), module(OrderAggregate)],
      ~readModels=[module(AvailableProductsReadModel), module(CustomersReadModel), module(OrdersReadModel)],
      ~tasks=[module(OrderNotificationsTask)],
      ~pluginStructure=pluginStructure,
      ~uiFragments=?uiBundleUrl->Option.map(url =>
        Platform.Plugin.makeAutoUIManifest(
          ~remoteEntryUrl=url,
          ~name="Ordering",
          ~pluginStructure,
          ~readModelPositions=["platform-summary"],
          ~aggregatePositions=["resource-detail"],
        )
      ),
    )
}
