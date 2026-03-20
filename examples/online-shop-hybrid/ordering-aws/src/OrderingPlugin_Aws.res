// Ordering plugin — bundled variant for AWS deployment.
// Uses bundled Lambda handlers for all components.

open Reventless.Projection

let resolveModule = ReventlessAws.Util_Bundle.resolveModule
let orderingPkg = "@reventlessdev/online-shop-hybrid-ordering/src"

// DCB config registered in index.mjs (before ReScript module init)

module Make = (
  Platform: ReventlessInfra.Platform.T
    with type api = ReventlessAws.Types.AppSync.api
    and type role = ReventlessAws.Types.AppSync.role,
) => {
  // ── Customer Aggregate (BUNDLED) ─────────────────────────────
  module CustomerAggregate = ReventlessAws.Aggregate_Builder_Single.Make(
    OrderingPlugin.Customer,
    OrderingPlugin.CustomerBehavior,
    ReventlessInfra.NoEventMappings.Make(OrderingPlugin.Customer),
    {
      let specModulePath = resolveModule(
        orderingPkg ++ "/Customer/Aggregate/Customer.res.mjs",
      )
      let behaviorModulePath = resolveModule(
        orderingPkg ++ "/Customer/Aggregate/CustomerBehavior.res.mjs",
      )
    },
  )

  // ── Customers ReadModel (BUNDLED) ────────────────────────────
  module CustomerProjections: Mappings with module Target := OrderingPlugin.CustomersReadModel = {
    module M = Mappings.Make(OrderingPlugin.CustomersReadModel)
    module type Mapping = M.Mapping
    let mappings: array<module(Mapping)> = [
      module(OrderingPlugin.CustomersProjections.CustomerMapping),
    ]
  }

  module CustomerReadModel = ReventlessAws.ReadModel_Builder_Single.Make(
    OrderingPlugin.CustomersReadModel,
    CustomerProjections,
    {
      let specModulePath = resolveModule(
        orderingPkg ++ "/Customer/ReadModel/CustomersReadModel.res.mjs",
      )
      let mappingsModulePath = resolveModule(
        orderingPkg ++ "/Customer/ReadModel/CustomersProjections.res.mjs",
      )
    },
  )

  // ── Order/CatalogProduct DCB (standard — via Platform) ───────
  module OrderingEventLogMaker = Platform.DcbEventLog.Make(OrderingPlugin.OrderingEventLog)

  module PlaceOrderSlice = Platform.StateChangeSlice.Make(OrderingPlugin.PlaceOrder)
  module ShipOrderSlice = Platform.StateChangeSlice.Make(OrderingPlugin.ShipOrder)
  module CancelOrderSlice = Platform.StateChangeSlice.Make(OrderingPlugin.CancelOrder)
  module SyncCatalogProductSlice = Platform.StateChangeSlice.Make(
    OrderingPlugin.SyncCatalogProduct,
  )

  module AutoShipOrderSlice = Platform.AutomationSlice.Bundled.Make(
    OrderingPlugin.AutoShipOrder,
    {
      let specModulePath = resolveModule(
        orderingPkg ++ "/Order/AutomationSlice/AutoShipOrder.res.mjs",
      )
    },
  )
  module SendOrderConfirmationSlice = Platform.OutboundTranslationSlice.Bundled.Make(
    OrderingPlugin.SendOrderConfirmation,
    {
      let specModulePath = resolveModule(
        orderingPkg ++ "/Order/OutboundTranslationSlice/SendOrderConfirmation.res.mjs",
      )
    },
  )

  module OrdersViewSlice = Platform.StateViewSlice.Bundled.Make(
    OrderingPlugin.OrdersView,
    {
      let specModulePath = resolveModule(
        orderingPkg ++ "/Order/StateViewSlice/OrdersView.res.mjs",
      )
    },
  )
  module AvailableProductsViewSlice = Platform.StateViewSlice.Bundled.Make(
    OrderingPlugin.AvailableProductsView,
    {
      let specModulePath = resolveModule(
        orderingPkg ++ "/CatalogProduct/StateViewSlice/AvailableProductsView.res.mjs",
      )
    },
  )

  // ── Extension (standard — via Platform) ──────────────────────
  module ProductsExtensionMapping = ReventlessInfra.ExtensionMapping.Make(
    CatalogSpec.ProductsExtensionPoint,
    OrderingPlugin.ProductsExtension.ProductMapping,
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

  // ── Extension Point (BUNDLED) ────────────────────────────────
  module OrdersEPMappingT = ReventlessInfra.ExtensionPointMapping.Make(
    OrderingSpec.OrdersExtensionPoint,
    OrderingPlugin.OrdersExtensionPointMapping,
  )
  module OrdersEPMappings = {
    module Spec = OrderingSpec.OrdersExtensionPoint
    module type Mapping = ReventlessInfra.ExtensionPointMapping.T with module ExtensionPoint := Spec
    let mappings: array<module(Mapping)> = [module(OrdersEPMappingT)]
  }
  let orderingSpecPkg = "@reventlessdev/online-shop-hybrid-ordering-spec/src"
  module OrdersExtensionPointMaker = ReventlessAws.ExtensionPoint_Builder.Make(
    OrderingSpec.OrdersExtensionPoint,
    OrdersEPMappings,
    {
      let specModulePath = resolveModule(
        orderingSpecPkg ++ "/OrdersExtensionPoint.res.mjs",
      )
      let mappingsModulePath = resolveModule(
        orderingPkg ++ "/ExtensionPoint/OrdersExtensionPointMapping.res.mjs",
      )
      let publishToAggregatesQueueUrls = Dict.make()
    },
  )

  // ── DCB Spec ─────────────────────────────────────────────────
  module DcbSpec = {
    @schema
    type event = OrderingPlugin.OrderingEventLog.event
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
    > = [module(OrdersViewSlice), module(AvailableProductsViewSlice)]
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

  // ── Hybrid Plugin Assembly ───────────────────────────────────
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
