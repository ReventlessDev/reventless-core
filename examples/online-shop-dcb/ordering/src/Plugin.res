// AUTO-GENERATED — do not edit. Run `npm run generate` to update.
module Make = (Platform: ReventlessInfra.Platform.T) => {
  // StateChangeSlices
  module CancelOrderSlice = Platform.StateChangeSlice.Make(CancelOrder)
  module ChangeAddressSlice = Platform.StateChangeSlice.Make(ChangeAddress)
  module ChangeEmailSlice = Platform.StateChangeSlice.Make(ChangeEmail)
  module DeactivateCustomerSlice = Platform.StateChangeSlice.Make(DeactivateCustomer)
  module PlaceOrderSlice = Platform.StateChangeSlice.Make(PlaceOrder)
  module RegisterCustomerSlice = Platform.StateChangeSlice.Make(RegisterCustomer)
  module ShipOrderSlice = Platform.StateChangeSlice.Make(ShipOrder)
  module SyncCatalogProductSlice = Platform.StateChangeSlice.Make(SyncCatalogProduct)

  // StateViewSlices
  module AvailableProductsViewSlice = Platform.StateViewSlice.Make(AvailableProductsView)
  module CustomersViewSlice = Platform.StateViewSlice.Make(CustomersView)
  module OrdersViewSlice = Platform.StateViewSlice.Make(OrdersView)

  // AutomationSlices
  module AutoShipOrderSlice = Platform.AutomationSlice.Make(AutoShipOrder)

  // OutboundTranslationSlices
  module SendOrderConfirmationSlice = Platform.OutboundTranslationSlice.Make(SendOrderConfirmation)

  // ExtensionPoints
  module OrdersExtensionPointMaker = Platform.ExtensionPoint.Make(OrdersExtensionPointMapping)

  // Extensions
  module ProductsExtensionMaker = Platform.Extension.Make(ProductsExtension.Mapping)

  let pluginStructure = Platform.Plugin.makePluginDefinition(
    ~name="Ordering",
    ~stateViewSlices=[module(AvailableProductsViewSlice), module(CustomersViewSlice), module(OrdersViewSlice)],
    ~stateChangeSlices=[module(CancelOrderSlice), module(ChangeAddressSlice), module(ChangeEmailSlice), module(DeactivateCustomerSlice), module(PlaceOrderSlice), module(RegisterCustomerSlice), module(ShipOrderSlice), module(SyncCatalogProductSlice)],
    ~automationSlices=[module(AutoShipOrderSlice)],
    ~outboundTranslationSlices=[module(SendOrderConfirmationSlice)],
    ~extensions=[module(ProductsExtensionMaker)],
  )

  let make = () =>
    Platform.Plugin.make(
      ~name="Ordering",
      ~heartbeatInterval=60,
      ~extensionPoints=[module(OrdersExtensionPointMaker)],
      ~extensions=[module(ProductsExtensionMaker)],
      ~stateChangeSlices=[module(CancelOrderSlice), module(ChangeAddressSlice), module(ChangeEmailSlice), module(DeactivateCustomerSlice), module(PlaceOrderSlice), module(RegisterCustomerSlice), module(ShipOrderSlice), module(SyncCatalogProductSlice)],
      ~stateViewSlices=[module(AvailableProductsViewSlice), module(CustomersViewSlice), module(OrdersViewSlice)],
      ~automationSlices=[module(AutoShipOrderSlice)],
      ~outboundTranslationSlices=[module(SendOrderConfirmationSlice)],
      ~pluginStructure=pluginStructure,
    )
}
