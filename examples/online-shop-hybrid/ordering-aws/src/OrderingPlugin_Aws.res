// AUTO-GENERATED — do not edit. Run `npm run generate` to update.
open Reventless.Projection

module Make = (
  Platform: ReventlessInfra.Platform.T
    with type api = ReventlessAws.Types.AppSync.api
    and type role = ReventlessAws.Types.AppSync.role,
) => {
  // StateChangeSlices
  module CancelOrderSlice = Platform.StateChangeSlice.Make(OrderingPlugin.CancelOrder)
  module PlaceOrderSlice = Platform.StateChangeSlice.Make(OrderingPlugin.PlaceOrder)
  module RefundOrderSlice = Platform.StateChangeSlice.Make(OrderingPlugin.RefundOrder)
  module ShipOrderSlice = Platform.StateChangeSlice.Make(OrderingPlugin.ShipOrder)
  module SyncCatalogProductSlice = Platform.StateChangeSlice.Make(OrderingPlugin.SyncCatalogProduct)

  // StateViewSlices
  module AvailableProductsViewSlice = Platform.StateViewSlice.Make(OrderingPlugin.AvailableProductsView)
  module OrdersViewSlice = Platform.StateViewSlice.Make(OrderingPlugin.OrdersView)

  // AutomationSlices
  module AutoShipOrderSlice = Platform.AutomationSlice.Make(OrderingPlugin.AutoShipOrder)

  // OutboundTranslationSlices
  module SendOrderConfirmationSlice = Platform.OutboundTranslationSlice.Make(OrderingPlugin.SendOrderConfirmation)

  // Aggregates
  module CustomerAggregate = ReventlessAws.Aggregate_Builder_Single.Make(
    OrderingPlugin.Customer,
    OrderingPlugin.CustomerBehavior,
    ReventlessInfra.NoEventMappings.Make(OrderingPlugin.Customer),
  )

  // ReadModels
  @reventless.projections
  module CustomersProjectionsWrapper: Mappings with module Target := OrderingPlugin.CustomersReadModel = {
    let mappings: array<module(Mapping)> = [module(OrderingPlugin.CustomersProjections.CustomerMapping)]
  }
  module CustomersReadModelMaker = ReventlessAws.ReadModel_Builder_Single.Make(
    OrderingPlugin.CustomersReadModel,
    CustomersProjectionsWrapper,
  )

  // ExtensionPoints
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

  // Extensions
  module ProductsExtensionMaker = Platform.Extension.Make(OrderingPlugin.ProductsExtension.Mapping)

  let uiDefinition = Platform.Plugin.makeAutoUIDefinition(
    ~name="Ordering",
    ~aggregates=[module(CustomerAggregate)],
    ~readModels=[module(CustomersReadModelMaker)],
    ~stateViewSlices=[module(AvailableProductsViewSlice), module(OrdersViewSlice)],
    ~stateChangeSlices=[module(CancelOrderSlice), module(PlaceOrderSlice), module(RefundOrderSlice), module(ShipOrderSlice), module(SyncCatalogProductSlice)],
  )

  let make = () =>
    Platform.Plugin.make(
      ~name="Ordering",
      ~heartbeatInterval=60,
      ~extensionPoints=[module(OrdersExtensionPointMaker)],
      ~extensions=[module(ProductsExtensionMaker)],
      ~aggregates=[module(CustomerAggregate)],
      ~readModels=[module(CustomersReadModelMaker)],
      ~stateChangeSlices=[module(CancelOrderSlice), module(PlaceOrderSlice), module(RefundOrderSlice), module(ShipOrderSlice), module(SyncCatalogProductSlice)],
      ~stateViewSlices=[module(AvailableProductsViewSlice), module(OrdersViewSlice)],
      ~automationSlices=[module(AutoShipOrderSlice)],
      ~outboundTranslationSlices=[module(SendOrderConfirmationSlice)],
      ~uiDefinition=uiDefinition,
    )
}
