// AUTO-GENERATED — do not edit. Run `npm run generate` to update.

@val external uiBundleUrl: option<string> = "process.env.ORDERING_UI_BUNDLE_URL"

module Make = (Platform: ReventlessInfra.Platform.T) => {
  // StateChangeSlices
  module CancelOrderSlice = Platform.StateChangeSlice.Make(CancelOrder, CancelOrder_Behavior)
  module PlaceOrderSlice = Platform.StateChangeSlice.Make(PlaceOrder, PlaceOrder_Behavior)
  module RefundOrderSlice = Platform.StateChangeSlice.Make(RefundOrder, RefundOrder_Behavior)
  module ShipOrderSlice = Platform.StateChangeSlice.Make(ShipOrder, ShipOrder_Behavior)
  module SyncCatalogProductSlice = Platform.StateChangeSlice.Make(SyncCatalogProduct, SyncCatalogProduct_Behavior)

  // StateViewSliceStreams
  module AvailableProductsStreamSlice = Platform.StateViewSliceStream.Make(AvailableProducts, AvailableProducts_Projection)
  module OrdersStreamSlice = Platform.StateViewSliceStream.Make(Orders, Orders_Projection)

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
  module CustomersReadModel = Platform.ReadModelStream.Make(Customers, Customers_Projections)

  // ExtensionPoints
  module Orders_ExtensionPoint = Platform.ExtensionPoint.Make(Orders_ExtensionPointMapping)

  // Extensions
  module Products_Extension = Platform.Extension.Make(Products_Extension.Mapping)

  let pluginStructure = Platform.Plugin.makePluginDefinition(
    ~name="Ordering",
    ~aggregates=[module(CustomerAggregate)],
    ~readModels=[module(CustomersReadModel)],
    ~stateViewSlices=[module(AvailableProductsStreamSlice), module(OrdersStreamSlice)],
    ~stateChangeSlices=[module(CancelOrderSlice), module(PlaceOrderSlice), module(RefundOrderSlice), module(ShipOrderSlice), module(SyncCatalogProductSlice)],
    ~automationSlices=[module(AutoShipOrderSlice)],
    ~outboundTranslationSlices=[module(SendOrderConfirmationSlice)],
    ~extensions=[module(Products_Extension)],
    ~extensionPoints=[module(Orders_ExtensionPointMapping)],
    ~componentChapters=Dict.fromArray([("AutoShipOrder", "Order"), ("AvailableProducts", "CatalogProduct"), ("CancelOrder", "Order"), ("Customer", "Customer"), ("Customers", "Customer"), ("Orders", "Order"), ("PlaceOrder", "Order"), ("RefundOrder", "Order"), ("SendOrderConfirmation", "Order"), ("ShipOrder", "Order"), ("SyncCatalogProduct", "CatalogProduct")]),
  )

  let make = () =>
    Platform.Plugin.make(
      ~name="Ordering",
      ~heartbeatInterval=5,
      ~extensionPoints=[module(Orders_ExtensionPoint)],
      ~extensions=[module(Products_Extension)],
      ~aggregates=[module(CustomerAggregate)],
      ~readModels=[module(CustomersReadModel)],
      ~stateChangeSlices=[module(CancelOrderSlice), module(PlaceOrderSlice), module(RefundOrderSlice), module(ShipOrderSlice), module(SyncCatalogProductSlice)],
      ~stateViewSlices=[module(AvailableProductsStreamSlice), module(OrdersStreamSlice)],
      ~automationSlices=[module(AutoShipOrderSlice)],
      ~outboundTranslationSlices=[module(SendOrderConfirmationSlice)],
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
