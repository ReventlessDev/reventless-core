// Ordering DCB plugin — platform-agnostic composition root.
// Wires the shared event log, all StateChangeSlices, StateViewSlices, the
// OrdersExtensionPoint (outbound), and the ProductsExtension (inbound).

module Make = (Platform: ReventlessInfra.Platform.T) => {
  module OrderingEventLogMaker = Platform.DcbEventLog.Make(OrderingEventLog)

  module RegisterCustomerSlice = Platform.StateChangeSlice.Make(RegisterCustomer)
  module UpdateEmailSlice = Platform.StateChangeSlice.Make(UpdateEmail)
  module UpdateAddressSlice = Platform.StateChangeSlice.Make(UpdateAddress)
  module DeactivateCustomerSlice = Platform.StateChangeSlice.Make(DeactivateCustomer)

  module CustomersViewSlice = Platform.StateViewSlice.Make(CustomersView)

  module PlaceOrderSlice = Platform.StateChangeSlice.Make(PlaceOrder)
  module ShipOrderSlice = Platform.StateChangeSlice.Make(ShipOrder)
  module CancelOrderSlice = Platform.StateChangeSlice.Make(CancelOrder)

  module OrdersViewSlice = Platform.StateViewSlice.Make(OrdersView)

  // Catalog product shadow — driven by Catalog's ProductsExtensionPoint
  module SyncCatalogProductSlice = Platform.StateChangeSlice.Make(SyncCatalogProduct)
  module AvailableProductsViewSlice = Platform.StateViewSlice.Make(AvailableProductsView)

  // Build the Products extension (subscribing to Catalog's EP)
  module ProductsExtensionMaker = Platform.Extension.Make(
    ProductsExtensionPointSpec,
    ProductsExtension.Mappings,
  )

  // Compile the Orders extension point mapping, then build the EP component
  module OrdersEPMappingT = ReventlessInfra.ExtensionPointMapping.Make(
    OrdersExtensionPointSpec,
    OrdersExtensionPointMapping,
  )
  module OrdersEPMappings = {
    module Spec = OrdersExtensionPointSpec
    module type Mapping = ReventlessInfra.ExtensionPointMapping.T with module ExtensionPoint := Spec
    let mappings: array<module(Mapping)> = [module(OrdersEPMappingT)]
  }
  module OrdersExtensionPointMaker = Platform.ExtensionPoint.Make(
    OrdersExtensionPointSpec,
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
      module(UpdateEmailSlice),
      module(UpdateAddressSlice),
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
    > = []
    let outboundTranslationSlices: array<
      module(ReventlessInfra.OutboundTranslationSlice.T with type dcbEvent = event),
    > = []
    let inboundTranslationSlices: array<
      module(ReventlessInfra.InboundTranslationSlice.T with type dcbEvent = event),
    > = []
  }

  let make = (
    ~scheduler: Pulumi.Output.t<ReventlessInfra.Scheduler.operations>,
    ~api: Platform.api,
    ~apiRole: Platform.role,
  ) =>
    Platform.Plugin.make(
      ~name="Ordering",
      ~version="1.0.0",
      ~heartbeatInterval=60,
      ~extensionPoints=[module(OrdersExtensionPointMaker)],
      ~extensions=[module(ProductsExtensionMaker)],
      ~api,
      ~apiRole,
      ~scheduler,
      ~dcbSpec=module(DcbSpec),
    )
}
