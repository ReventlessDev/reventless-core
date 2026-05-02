// AUTO-GENERATED — do not edit. Run `npm run generate` to update.
module Make = (Platform: ReventlessInfra.Platform.T) => {
  // StateChangeSlices
  module CancelOrderSlice = Platform.StateChangeSlice.Make(CancelOrder, CancelOrder_Behavior)
  module ChangeAddressSlice = Platform.StateChangeSlice.Make(ChangeAddress, ChangeAddress_Behavior)
  module ChangeEmailSlice = Platform.StateChangeSlice.Make(ChangeEmail, ChangeEmail_Behavior)
  module DeactivateCustomerSlice = Platform.StateChangeSlice.Make(DeactivateCustomer, DeactivateCustomer_Behavior)
  module PlaceOrderSlice = Platform.StateChangeSlice.Make(PlaceOrder, PlaceOrder_Behavior)
  module RegisterCustomerSlice = Platform.StateChangeSlice.Make(RegisterCustomer, RegisterCustomer_Behavior)
  module ShipOrderSlice = Platform.StateChangeSlice.Make(ShipOrder, ShipOrder_Behavior)
  module SyncCatalogProductSlice = Platform.StateChangeSlice.Make(SyncCatalogProduct, SyncCatalogProduct_Behavior)

  // StateViewSlices
  module AvailableProductsViewSlice = Platform.StateViewSlice.Make(AvailableProductsView, AvailableProductsView_Projection)
  module CustomersViewSlice = Platform.StateViewSlice.Make(CustomersView, CustomersView_Projection)
  module OrdersViewSlice = Platform.StateViewSlice.Make(OrdersView, OrdersView_Projection)

  // AutomationSlices
  module AutoShipOrderSlice = Platform.AutomationSlice.Make(AutoShipOrder, AutoShipOrder_Automation)

  // OutboundTranslationSlices
  module SendOrderConfirmationSlice = Platform.OutboundTranslationSlice.Make(SendOrderConfirmation, SendOrderConfirmation_Translation)

  // ExtensionPoints
  module OrdersExtensionPoint = Platform.ExtensionPoint.Make(OrdersExtensionPointMapping)

  // Extensions
  module ProductsExtension = Platform.Extension.Make(ProductsExtension.Mapping)

  let pluginStructure = Platform.Plugin.makePluginDefinition(
    ~name="Ordering",
    ~stateViewSlices=[module(AvailableProductsViewSlice), module(CustomersViewSlice), module(OrdersViewSlice)],
    ~stateChangeSlices=[module(CancelOrderSlice), module(ChangeAddressSlice), module(ChangeEmailSlice), module(DeactivateCustomerSlice), module(PlaceOrderSlice), module(RegisterCustomerSlice), module(ShipOrderSlice), module(SyncCatalogProductSlice)],
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
      ~stateChangeSlices=[module(CancelOrderSlice), module(ChangeAddressSlice), module(ChangeEmailSlice), module(DeactivateCustomerSlice), module(PlaceOrderSlice), module(RegisterCustomerSlice), module(ShipOrderSlice), module(SyncCatalogProductSlice)],
      ~stateViewSlices=[module(AvailableProductsViewSlice), module(CustomersViewSlice), module(OrdersViewSlice)],
      ~automationSlices=[module(AutoShipOrderSlice)],
      ~outboundTranslationSlices=[module(SendOrderConfirmationSlice)],
      ~pluginStructure=pluginStructure,
    )
}
