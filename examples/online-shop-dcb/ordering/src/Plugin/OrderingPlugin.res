// Ordering DCB plugin — platform-agnostic composition root.
// Wires the shared event log, all StateChangeSlices, StateViewSlices, the
// OrdersExtensionPoint (outbound), and the ProductsExtension (inbound).

module Make = (Platform: ReventlessInfra.Platform.T) => {
  module OrderingEventLogMaker = Platform.DcbEventLog.Make(OrderingEventLog)

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
  module ProductsExtensionMapping = ReventlessInfra.ExtensionMapping.Make(
    CatalogSpec.ProductsExtensionPoint,
    ProductsExtension.ProductMapping,
  )
  module ProductsExtensionMappings = {
    module Spec = CatalogSpec.ProductsExtensionPoint
    module type Mapping = ReventlessInfra.ExtensionMapping.T
      with module ExtensionPoint := Spec
    let name = "OrderingProducts"
    let moduleUrl: string = %raw(`import.meta.url`)
    let mappings: array<module(Mapping)> = [module(ProductsExtensionMapping)]
  }
  module ProductsExtensionMaker = Platform.Extension.Make(
    CatalogSpec.ProductsExtensionPoint,
    ProductsExtensionMappings,
  )

  // Compile the Orders extension point mapping, then build the EP component
  module OrdersEPMappingT = ReventlessInfra.ExtensionPointMapping.Make(
    OrderingSpec.OrdersExtensionPoint,
    OrdersExtensionPointMapping,
  )
  module OrdersEPMappings = {
    module Spec = OrderingSpec.OrdersExtensionPoint
    module type Mapping = ReventlessInfra.ExtensionPointMapping.T with module ExtensionPoint := Spec
    let name = "OrdersEPMappings"
    let moduleUrl: string = %raw(`import.meta.url`)
    let mappings: array<module(Mapping)> = [module(OrdersEPMappingT)]
  }
  module OrdersExtensionPointMaker = Platform.ExtensionPoint.Make(
    OrderingSpec.OrdersExtensionPoint,
    OrdersEPMappings,
  )

  // --- Self-assembly: produce a ready-to-use Plugin.component ---

  module DcbSpec = {
    @schema
    type event = OrderingEventLog.event
    let stateChangeSlices: array<
      module(ReventlessInfra.StateChangeSlice.T with type dcbEvent = event),
    > = [
      module(RegisterCustomerSlice),
      module(ChangeEmailSlice),
      module(ChangeAddressSlice),
      module(DeactivateCustomerSlice),
      module(PlaceOrderSlice),
      module(ShipOrderSlice),
      module(CancelOrderSlice),
      module(SyncCatalogProductSlice),
    ]
    let stateViewSlices: array<
      module(ReventlessInfra.StateViewSlice.T with type dcbEvent = event),
    > = [
      module(CustomersViewSlice),
      module(OrdersViewSlice),
      module(AvailableProductsViewSlice),
    ]
    let automationSlices: array<
      module(ReventlessInfra.AutomationSlice.T with type dcbEvent = event),
    > = [module(AutoShipOrderSlice)]
    let outboundTranslationSlices: array<
      module(ReventlessInfra.OutboundTranslationSlice.T with type dcbEvent = event),
    > = [module(SendOrderConfirmationSlice)]
    let inboundTranslationSlices: array<
      module(ReventlessInfra.InboundTranslationSlice.T with type dcbEvent = event),
    > = []
  }

  let make = (~scheduler, ~api, ~apiRole) =>
    Platform.Plugin.make(
      ~name="Ordering",
      ~heartbeatInterval=60,
      ~extensionPoints=[module(OrdersExtensionPointMaker)],
      ~extensions=[module(ProductsExtensionMaker)],
      ~api,
      ~apiRole,
      ~scheduler,
      ~dcbSpec=module(DcbSpec),
    )
}
