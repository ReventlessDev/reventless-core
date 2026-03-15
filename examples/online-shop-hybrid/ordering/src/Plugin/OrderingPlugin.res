// Ordering hybrid plugin — platform-agnostic composition root.
// Combines Customer as an aggregate with Order/CatalogProduct as DCB slices.
// Demonstrates the hybrid approach: independent entities as aggregates,
// interdependent entities as DCB slices sharing an event log.

open Reventless.Projection

module Make = (Platform: ReventlessInfra.Platform.T) => {
  // ── Customer Aggregate ──────────────────────────────────────
  module CustomerAggregate = Platform.Aggregate.Make(
    Customer,
    CustomerBehavior,
    ReventlessInfra.NoEventMappings.Make(Customer),
  )

  module CustomerProjections: Mappings with module Target := CustomersReadModel = {
    module M = Mappings.Make(CustomersReadModel)
    module type Mapping = M.Mapping
    let mappings: array<module(Mapping)> = [module(CustomersProjections.CustomerMapping)]
  }

  module CustomerReadModel = Platform.ReadModel.Make(CustomersReadModel, CustomerProjections)

  // ── Order/CatalogProduct DCB ────────────────────────────────
  module OrderingEventLogMaker = Platform.DcbEventLog.Make(OrderingEventLog)

  module PlaceOrderSlice = Platform.StateChangeSlice.Make(PlaceOrder)
  module ShipOrderSlice = Platform.StateChangeSlice.Make(ShipOrder)
  module CancelOrderSlice = Platform.StateChangeSlice.Make(CancelOrder)

  module AutoShipOrderSlice = Platform.AutomationSlice.Make(AutoShipOrder)
  module SendOrderConfirmationSlice = Platform.OutboundTranslationSlice.Make(SendOrderConfirmation)

  module OrdersViewSlice = Platform.StateViewSlice.Make(OrdersView)

  module SyncCatalogProductSlice = Platform.StateChangeSlice.Make(SyncCatalogProduct)
  module AvailableProductsViewSlice = Platform.StateViewSlice.Make(AvailableProductsView)

  // ── Extension (inbound from Catalog) ────────────────────────
  module ProductsExtensionMapping = ReventlessInfra.ExtensionMapping.Make(
    CatalogSpec.ProductsExtensionPoint,
    ProductsExtension.ProductMapping,
  )
  module ProductsExtensionMappings = {
    module Spec = CatalogSpec.ProductsExtensionPoint
    module type Mapping = ReventlessInfra.ExtensionMapping.T
      with module ExtensionPoint := Spec
    let name = "OrderingProducts"
    let mappings: array<module(Mapping)> = [module(ProductsExtensionMapping)]
  }
  module ProductsExtensionMaker = Platform.Extension.Make(
    CatalogSpec.ProductsExtensionPoint,
    ProductsExtensionMappings,
  )

  // ── Extension Point (outbound) ──────────────────────────────
  module OrdersEPMappingT = ReventlessInfra.ExtensionPointMapping.Make(
    OrderingSpec.OrdersExtensionPoint,
    OrdersExtensionPointMapping,
  )
  module OrdersEPMappings = {
    module Spec = OrderingSpec.OrdersExtensionPoint
    module type Mapping = ReventlessInfra.ExtensionPointMapping.T with module ExtensionPoint := Spec
    let mappings: array<module(Mapping)> = [module(OrdersEPMappingT)]
  }
  module OrdersExtensionPointMaker = Platform.ExtensionPoint.Make(
    OrderingSpec.OrdersExtensionPoint,
    OrdersEPMappings,
  )

  // ── DCB Spec (excludes Customer — it's an aggregate) ───────
  module DcbSpec = {
    @schema
    type event = OrderingEventLog.event
    let stateChangeSlices: array<
      module(ReventlessInfra.StateChangeSlice.T with type dcbEvent = event),
    > = [
      module(PlaceOrderSlice),
      module(ShipOrderSlice),
      module(CancelOrderSlice),
      module(SyncCatalogProductSlice),
    ]
    let stateViewSlices: array<
      module(ReventlessInfra.StateViewSlice.T with type dcbEvent = event),
    > = [
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

  // ── Hybrid Plugin Assembly ──────────────────────────────────
  let make = (~scheduler, ~api, ~apiRole) =>
    Platform.Plugin.make(
      ~name="Ordering",
      ~heartbeatInterval=60,
      ~aggregates=[module(CustomerAggregate)],
      ~readModels=[module(CustomerReadModel)],
      ~extensionPoints=[module(OrdersExtensionPointMaker)],
      ~extensions=[module(ProductsExtensionMaker)],
      ~api,
      ~apiRole,
      ~scheduler,
      ~dcbSpec=module(DcbSpec),
    )
}
