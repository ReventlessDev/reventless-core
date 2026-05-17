// AUTO-GENERATED — do not edit. Run `npm run generate` to update.
module Make = (Platform: ReventlessInfra.Platform.T) => {
  // StateChangeSlices
  module CancelOrderSlice = Platform.StateChangeSlice.Make(CancelOrder, CancelOrder_Behavior)
  module PlaceOrderSlice = Platform.StateChangeSlice.Make(PlaceOrder, PlaceOrder_Behavior)
  module RefundOrderSlice = Platform.StateChangeSlice.Make(RefundOrder, RefundOrder_Behavior)
  module ShipOrderSlice = Platform.StateChangeSlice.Make(ShipOrder, ShipOrder_Behavior)
  module SyncCatalogProductSlice = Platform.StateChangeSlice.Make(SyncCatalogProduct, SyncCatalogProduct_Behavior)

  // StateViewSlices
  module AvailableProductsSlice = Platform.StateViewSlice.Make(AvailableProducts, AvailableProducts_Projection)
  module OrdersSlice = Platform.StateViewSlice.Make(Orders, Orders_Projection)

  // AutomationSlices
  module AutoShipOrderSlice = Platform.AutomationSlice.Make(AutoShipOrder, AutoShipOrder_Automation)

  // OutboundTranslationSlices
  module SendOrderConfirmationSlice = Platform.OutboundTranslationSlice.Make(SendOrderConfirmation, SendOrderConfirmation_Translation)

  // Aggregates
  module CustomerAggregate = Platform.Aggregate.Make(
    Customer,
    Customer_Behavior,
    ReventlessInfra.NoEventMappings.Make(Customer),
  )

  // ReadModels
  module CustomersReadModel = Platform.ReadModel.Make(Customers, Customers_Projections)

  // ExtensionPoints
  module Orders_ExtensionPoint = Platform.ExtensionPoint.Make(Orders_ExtensionPointMapping)

  // Extensions
  module Products_Extension = Platform.Extension.Make(Products_Extension.Mapping)

  let pluginStructure = Platform.Plugin.makePluginDefinition(
    ~name="Ordering",
    ~aggregates=[module(CustomerAggregate)],
    ~readModels=[module(CustomersReadModel)],
    ~stateViewSlices=[module(AvailableProductsSlice), module(OrdersSlice)],
    ~stateChangeSlices=[module(CancelOrderSlice), module(PlaceOrderSlice), module(RefundOrderSlice), module(ShipOrderSlice), module(SyncCatalogProductSlice)],
    ~automationSlices=[module(AutoShipOrderSlice)],
    ~outboundTranslationSlices=[module(SendOrderConfirmationSlice)],
    ~extensions=[module(Products_Extension)],
  )

  let make = (~uiBundleUrl=?) =>
    Platform.Plugin.make(
      ~name="Ordering",
      ~heartbeatInterval=5,
      ~extensionPoints=[module(Orders_ExtensionPoint)],
      ~extensions=[module(Products_Extension)],
      ~aggregates=[module(CustomerAggregate)],
      ~readModels=[module(CustomersReadModel)],
      ~stateChangeSlices=[module(CancelOrderSlice), module(PlaceOrderSlice), module(RefundOrderSlice), module(ShipOrderSlice), module(SyncCatalogProductSlice)],
      ~stateViewSlices=[module(AvailableProductsSlice), module(OrdersSlice)],
      ~automationSlices=[module(AutoShipOrderSlice)],
      ~outboundTranslationSlices=[module(SendOrderConfirmationSlice)],
      ~pluginStructure=pluginStructure,
      ~uiFragments=?uiBundleUrl->Option.map(url =>
        Platform.Plugin.makeAutoUIManifest(
          ~remoteEntryUrl=url,
          ~name="Ordering",
          ~aggregates=[module(CustomerAggregate)],
          ~readModels=[module(CustomersReadModel)],
          ~readModelPositions=["platform-summary"],
          ~aggregatePositions=["resource-detail"],
        )
      ),
    )
}
