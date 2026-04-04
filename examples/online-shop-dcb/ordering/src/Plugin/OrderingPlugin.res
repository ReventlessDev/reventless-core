// Ordering DCB plugin — platform-agnostic composition root.
// Wires the shared event log, all StateChangeSlices, StateViewSlices, the
// OrdersExtensionPoint (outbound), and the ProductsExtension (inbound).

module Make = (Platform: ReventlessInfra.Platform.T) => {
  module RegisterCustomerSlice = Platform.StateChangeSlice.Make(RegisterCustomer)
  module ChangeEmailSlice = Platform.StateChangeSlice.Make(ChangeEmail)
  module ChangeAddressSlice = Platform.StateChangeSlice.Make(ChangeAddress)
  module DeactivateCustomerSlice = Platform.StateChangeSlice.Make(DeactivateCustomer)

  module CustomersViewSlice = Platform.StateViewSlice.Make(CustomersView)

  module PlaceOrderSlice = Platform.StateChangeSlice.Make(PlaceOrder)
  module ShipOrderSlice = Platform.StateChangeSlice.Make(ShipOrder)
  module CancelOrderSlice = Platform.StateChangeSlice.Make(CancelOrder)

  module AutoShipOrderSlice = Platform.AutomationSlice.Make(AutoShipOrder)
  module SendOrderConfirmationSlice = Platform.OutboundTranslationSlice.Make(SendOrderConfirmation)

  module OrdersViewSlice = Platform.StateViewSlice.Make(OrdersView)

  // Catalog product shadow — driven by Catalog's ProductsExtensionPoint
  module SyncCatalogProductSlice = Platform.StateChangeSlice.Make(SyncCatalogProduct)
  module AvailableProductsViewSlice = Platform.StateViewSlice.Make(AvailableProductsView)

  // Build the Products extension (subscribing to Catalog's EP)
  module ProductsExtensionMaker = Platform.Extension.Make(
    ProductsExtension.ProductMapping,
  )

  // Build the Orders extension point component
  module OrdersExtensionPointMaker = Platform.ExtensionPoint.Make(
    OrdersExtensionPointMapping,
    {let moduleUrl: string = %raw(`import.meta.url`)},
  )

  // --- Self-assembly: produce a ready-to-use Plugin.component ---

  let make = () =>
    Platform.Plugin.make(
      ~name="Ordering",
      ~heartbeatInterval=60,
      ~extensionPoints=[module(OrdersExtensionPointMaker)],
      ~extensions=[module(ProductsExtensionMaker)],
      ~stateChangeSlices=[
        module(RegisterCustomerSlice),
        module(ChangeEmailSlice),
        module(ChangeAddressSlice),
        module(DeactivateCustomerSlice),
        module(PlaceOrderSlice),
        module(ShipOrderSlice),
        module(CancelOrderSlice),
        module(SyncCatalogProductSlice),
      ],
      ~stateViewSlices=[
        module(CustomersViewSlice),
        module(OrdersViewSlice),
        module(AvailableProductsViewSlice),
      ],
      ~automationSlices=[module(AutoShipOrderSlice)],
      ~outboundTranslationSlices=[module(SendOrderConfirmationSlice)],
    )
}
