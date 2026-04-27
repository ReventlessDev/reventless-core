// AUTO-GENERATED — do not edit. Run `npm run generate` to update.
open Reventless.Projection

module Make = (
  Platform: ReventlessInfra.Platform.T
    with type api = ReventlessAws.Types.AppSync.api
    and type role = ReventlessAws.Types.AppSync.role,
) => {
  open OrderingPlugin

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
  module AutoShipOrderSlice = Platform.AutomationSlice.Make(AutoShipOrder, AutoShipOrder_Automation, AutoShipOrder_Mappings)

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
  module CustomersReadModel = Platform.ReadModel.Make(CustomersReadModel, CustomersProjectionsWrapper)

  // ExtensionPoints
  module OrdersExtensionPoint = Platform.ExtensionPoint.Make(OrdersExtensionPointMapping)

  // Extensions
  module ProductsExtension = Platform.Extension.Make(ProductsExtension.Mapping)

  let pluginStructure = Platform.Plugin.makePluginDefinition(
    ~name="Ordering",
    ~aggregates=[module(CustomerAggregate)],
    ~readModels=[module(CustomersReadModel)],
    ~stateViewSlices=[module(AvailableProductsViewSlice), module(OrdersViewSlice)],
    ~stateChangeSlices=[module(CancelOrderSlice), module(PlaceOrderSlice), module(RefundOrderSlice), module(ShipOrderSlice), module(SyncCatalogProductSlice)],
    ~automationSlices=[module(AutoShipOrderSlice)],
    ~outboundTranslationSlices=[module(SendOrderConfirmationSlice)],
    ~extensions=[module(ProductsExtension)],
  )

  let make = () =>
    Platform.Plugin.make(
      ~name="Ordering",
      ~heartbeatInterval=60,
      ~extensionPoints=[module(OrdersExtensionPoint)],
      ~extensions=[module(ProductsExtension)],
      ~aggregates=[module(CustomerAggregate)],
      ~readModels=[module(CustomersReadModel)],
      ~stateChangeSlices=[module(CancelOrderSlice), module(PlaceOrderSlice), module(RefundOrderSlice), module(ShipOrderSlice), module(SyncCatalogProductSlice)],
      ~stateViewSlices=[module(AvailableProductsViewSlice), module(OrdersViewSlice)],
      ~automationSlices=[module(AutoShipOrderSlice)],
      ~outboundTranslationSlices=[module(SendOrderConfirmationSlice)],
      ~pluginStructure=pluginStructure,
    )
}
