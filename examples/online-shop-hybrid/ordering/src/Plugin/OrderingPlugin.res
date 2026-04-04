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
    let moduleUrl: string = %raw(`import.meta.url`)
    let mappings: array<module(Mapping)> = [module(CustomersProjections.CustomerMapping)]
  }

  module CustomerReadModel = Platform.ReadModel.Make(CustomersReadModel, CustomerProjections)

  // ── Order/CatalogProduct DCB ────────────────────────────────
  module PlaceOrderSlice = Platform.StateChangeSlice.Make(PlaceOrder)
  module ShipOrderSlice = Platform.StateChangeSlice.Make(ShipOrder)
  module CancelOrderSlice = Platform.StateChangeSlice.Make(CancelOrder)

  module AutoShipOrderSlice = Platform.AutomationSlice.Make(AutoShipOrder)
  module SendOrderConfirmationSlice = Platform.OutboundTranslationSlice.Make(SendOrderConfirmation)

  module OrdersViewSlice = Platform.StateViewSlice.Make(OrdersView)

  module SyncCatalogProductSlice = Platform.StateChangeSlice.Make(SyncCatalogProduct)
  module AvailableProductsViewSlice = Platform.StateViewSlice.Make(AvailableProductsView)

  // ── Extension (inbound from Catalog) ────────────────────────
  module ProductsExtensionMaker = Platform.Extension.Make(
    CatalogSpec.ProductsExtensionPoint,
    ProductsExtension.ProductMapping,
  )

  // ── Extension Point (outbound) ──────────────────────────────
  module OrdersExtensionPointMaker = Platform.ExtensionPoint.Make(
    OrderingSpec.OrdersExtensionPoint,
    OrdersExtensionPointMapping,
    {let moduleUrl: string = %raw(`import.meta.url`)},
  )

  // ── Hybrid Plugin Assembly ──────────────────────────────────
  let make = () =>
    Platform.Plugin.make(
      ~name="Ordering",
      ~heartbeatInterval=60,
      ~aggregates=[module(CustomerAggregate)],
      ~readModels=[module(CustomerReadModel)],
      ~extensionPoints=[module(OrdersExtensionPointMaker)],
      ~extensions=[module(ProductsExtensionMaker)],
      ~stateChangeSlices=[
        module(PlaceOrderSlice),
        module(ShipOrderSlice),
        module(CancelOrderSlice),
        module(SyncCatalogProductSlice),
      ],
      ~stateViewSlices=[
        module(OrdersViewSlice),
        module(AvailableProductsViewSlice),
      ],
      ~automationSlices=[module(AutoShipOrderSlice)],
      ~outboundTranslationSlices=[module(SendOrderConfirmationSlice)],
    )
}
