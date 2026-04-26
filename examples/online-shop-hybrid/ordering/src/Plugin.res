// AUTO-GENERATED — do not edit. Run `npm run generate` to update.
open Reventless.Projection

module Make = (Platform: ReventlessInfra.Platform.T) => {
  // StateChangeSlices
  module CancelOrderSlice = Platform.StateChangeSlice.Make(CancelOrder, CancelOrder_Behavior)
  module PlaceOrderSlice = Platform.StateChangeSlice.Make(PlaceOrder, PlaceOrder_Behavior)
  module RefundOrderSlice = Platform.StateChangeSlice.Make(RefundOrder, RefundOrder_Behavior)
  module ShipOrderSlice = Platform.StateChangeSlice.Make(ShipOrder, ShipOrder_Behavior)
  module SyncCatalogProductSlice = Platform.StateChangeSlice.Make(SyncCatalogProduct, SyncCatalogProduct_Behavior)

  // StateViewSlices
  module AvailableProductsViewSlice = Platform.StateViewSlice.Make(AvailableProductsView, AvailableProductsView_Projection)
  module OrdersViewSlice = Platform.StateViewSlice.Make(OrdersView, OrdersView_Projection)

  // AutomationSlices
  module AutoShipOrderSlice = Platform.AutomationSlice.Make(AutoShipOrder, AutoShipOrder_Automation)

  // OutboundTranslationSlices
  module SendOrderConfirmationSlice = Platform.OutboundTranslationSlice.Make(SendOrderConfirmation, SendOrderConfirmation_Translation)

  // Aggregates
  module CustomerAggregate = Platform.Aggregate.Make(
    Customer,
    CustomerBehavior,
    ReventlessInfra.NoEventMappings.Make(Customer),
  )

  // ReadModels
  @reventless.projections
  module CustomersProjectionsWrapper: Mappings with module Target := CustomersReadModel = {
    let mappings: array<module(Mapping)> = [module(CustomersProjections.CustomerMapping)]
  }
  module CustomersReadModelMaker = Platform.ReadModel.Make(CustomersReadModel, CustomersProjectionsWrapper)

  // ExtensionPoints
  module OrdersExtensionPointMaker = Platform.ExtensionPoint.Make(OrdersExtensionPointMapping)

  // Extensions
  module ProductsExtensionMaker = Platform.Extension.Make(ProductsExtension.Mapping)

  let pluginStructure = Platform.Plugin.makePluginDefinition(
    ~name="Ordering",
    ~aggregates=[module(CustomerAggregate)],
    ~readModels=[module(CustomersReadModelMaker)],
    ~stateViewSlices=[module(AvailableProductsViewSlice), module(OrdersViewSlice)],
    ~stateChangeSlices=[module(CancelOrderSlice), module(PlaceOrderSlice), module(RefundOrderSlice), module(ShipOrderSlice), module(SyncCatalogProductSlice)],
    ~automationSlices=[module(AutoShipOrderSlice)],
    ~outboundTranslationSlices=[module(SendOrderConfirmationSlice)],
    ~extensions=[module(ProductsExtensionMaker)],
  )

  let make = (~uiBundleUrl=?) =>
    Platform.Plugin.make(
      ~name="Ordering",
      ~heartbeatInterval=60,
      ~extensionPoints=[module(OrdersExtensionPointMaker)],
      ~extensions=[module(ProductsExtensionMaker)],
      ~aggregates=[module(CustomerAggregate)],
      ~readModels=[module(CustomersReadModelMaker)],
      ~stateChangeSlices=[module(CancelOrderSlice), module(PlaceOrderSlice), module(RefundOrderSlice), module(ShipOrderSlice), module(SyncCatalogProductSlice)],
      ~stateViewSlices=[module(AvailableProductsViewSlice), module(OrdersViewSlice)],
      ~automationSlices=[module(AutoShipOrderSlice)],
      ~outboundTranslationSlices=[module(SendOrderConfirmationSlice)],
      ~pluginStructure=pluginStructure,
      ~uiFragments=?uiBundleUrl->Option.map(url =>
        Platform.Plugin.makeAutoUIManifest(
          ~remoteEntryUrl=url,
          ~name="Ordering",
          ~aggregates=[module(CustomerAggregate)],
          ~readModels=[module(CustomersReadModelMaker)],
          ~readModelPositions=["platform-summary"],
          ~aggregatePositions=["resource-detail"],
        )
      ),
    )
}
