// Ordering plugin — AWS deployment.

open Reventless.Projection

// DCB config registered in index.mjs (before ReScript module init)

module Make = (
  Platform: ReventlessInfra.Platform.T
    with type api = ReventlessAws.Types.AppSync.api
    and type role = ReventlessAws.Types.AppSync.role,
) => {
  // ── Customer Aggregate ────────────────────────────────────────
  module CustomerAggregate = ReventlessAws.Aggregate_Builder_Single.Make(
    OrderingPlugin.Customer,
    OrderingPlugin.CustomerBehavior,
    ReventlessInfra.NoEventMappings.Make(OrderingPlugin.Customer),
  )

  // ── Customers ReadModel ───────────────────────────────────────
  module CustomerProjections: Mappings with module Target := OrderingPlugin.CustomersReadModel = {
    module M = Mappings.Make(OrderingPlugin.CustomersReadModel)
    module type Mapping = M.Mapping
    let moduleUrl: string = %raw(`import.meta.url`)
    let mappings: array<module(Mapping)> = [
      module(OrderingPlugin.CustomersProjections.CustomerMapping),
    ]
  }

  module CustomerReadModel = ReventlessAws.ReadModel_Builder_Single.Make(
    OrderingPlugin.CustomersReadModel,
    CustomerProjections,
  )

  // ── Order/CatalogProduct DCB (standard — via Platform) ───────
  module PlaceOrderSlice = Platform.StateChangeSlice.Make(OrderingPlugin.PlaceOrder)
  module ShipOrderSlice = Platform.StateChangeSlice.Make(OrderingPlugin.ShipOrder)
  module CancelOrderSlice = Platform.StateChangeSlice.Make(OrderingPlugin.CancelOrder)
  module SyncCatalogProductSlice = Platform.StateChangeSlice.Make(
    OrderingPlugin.SyncCatalogProduct,
  )

  module AutoShipOrderSlice = Platform.AutomationSlice.Make(
    OrderingPlugin.AutoShipOrder,
  )
  module SendOrderConfirmationSlice = Platform.OutboundTranslationSlice.Make(
    OrderingPlugin.SendOrderConfirmation,
  )

  module OrdersViewSlice = Platform.StateViewSlice.Make(
    OrderingPlugin.OrdersView,
  )
  module AvailableProductsViewSlice = Platform.StateViewSlice.Make(
    OrderingPlugin.AvailableProductsView,
  )

  // ── Extension (standard — via Platform) ──────────────────────
  module ProductsExtensionMaker = Platform.Extension.Make(
    OrderingPlugin.ProductsExtension.ProductMapping,
  )

  // ── Extension Point ───────────────────────────────────────────
  module OrdersEPMappingT = ReventlessInfra.ExtensionPointMapping.Make(
    OrderingPlugin.OrdersExtensionPointMapping,
  )
  module OrdersEPMappings = {
    module Spec = OrderingPlugin.OrdersExtensionPointMapping.ExtensionPoint
    module type Mapping = ReventlessInfra.ExtensionPointMapping.T with module ExtensionPoint := Spec
    let name = "OrdersEPMappings"
    let moduleUrl: string = %raw(`import.meta.url`)
    let mappings: array<module(Mapping)> = [module(OrdersEPMappingT)]
  }
  module OrdersExtensionPointMaker = ReventlessAws.ExtensionPoint_Builder.Make(
    OrdersEPMappings.Spec,
    OrdersEPMappings,
    {
      let publishToAggregatesQueueUrls = Dict.make()
    },
  )

  // ── Hybrid Plugin Assembly ───────────────────────────────────
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
