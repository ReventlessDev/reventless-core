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

  // extensionPoints = [module(OrdersExtensionPointMaker)]
  // extensions     = [module(ProductsExtensionMaker)]

  module DcbSpec = OrderingEventLog
}
