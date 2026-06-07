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
  module AvailableProductsSlice = Platform.StateViewSlice.Make(AvailableProducts, AvailableProducts_Projection)
  module CustomersSlice = Platform.StateViewSlice.Make(Customers, Customers_Projection)
  module OrdersSlice = Platform.StateViewSlice.Make(Orders, Orders_Projection)

  // AutomationSlices
  module AutoShipOrderSlice = Platform.AutomationSlice.Make(AutoShipOrder, AutoShipOrder_Automation)

  // OutboundTranslationSlices
  module SendOrderConfirmationSlice = Platform.OutboundTranslationSlice.Make(SendOrderConfirmation, SendOrderConfirmation_Translation)

  // ExtensionPoints
  module Orders_ExtensionPoint = Platform.ExtensionPoint.Make(Orders_ExtensionPointMapping)

  // Extensions
  module Products_Extension = Platform.Extension.Make(Products_Extension.Mapping)

  let pluginStructure = Platform.Plugin.makePluginDefinition(
    ~name="Ordering",
    ~stateViewSlices=[module(AvailableProductsSlice), module(CustomersSlice), module(OrdersSlice)],
    ~stateChangeSlices=[module(CancelOrderSlice), module(ChangeAddressSlice), module(ChangeEmailSlice), module(DeactivateCustomerSlice), module(PlaceOrderSlice), module(RegisterCustomerSlice), module(ShipOrderSlice), module(SyncCatalogProductSlice)],
    ~automationSlices=[module(AutoShipOrderSlice)],
    ~outboundTranslationSlices=[module(SendOrderConfirmationSlice)],
    ~extensions=[module(Products_Extension)],
    ~extensionPoints=[module(Orders_ExtensionPointMapping)],
  )

  let make = () =>
    Platform.Plugin.make(
      ~name="Ordering",
      ~heartbeatInterval=5,
      ~extensionPoints=[module(Orders_ExtensionPoint)],
      ~extensions=[module(Products_Extension)],
      ~stateChangeSlices=[module(CancelOrderSlice), module(ChangeAddressSlice), module(ChangeEmailSlice), module(DeactivateCustomerSlice), module(PlaceOrderSlice), module(RegisterCustomerSlice), module(ShipOrderSlice), module(SyncCatalogProductSlice)],
      ~stateViewSlices=[module(AvailableProductsSlice), module(CustomersSlice), module(OrdersSlice)],
      ~automationSlices=[module(AutoShipOrderSlice)],
      ~outboundTranslationSlices=[module(SendOrderConfirmationSlice)],
      ~pluginStructure=pluginStructure,
    )
}
