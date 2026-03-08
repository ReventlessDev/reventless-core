// Catalog hybrid plugin — platform-agnostic composition root.
// Combines Category as an aggregate with Product/ProductDemand as DCB slices.
// Demonstrates the hybrid approach: independent entities as aggregates,
// interdependent entities as DCB slices sharing an event log.

open Reventless.Projection

module Make = (Platform: ReventlessInfra.Platform.T) => {
  // ── Category Aggregate ──────────────────────────────────────
  module CategoryAggregate = Platform.Aggregate.Make(
    Category,
    CategoryBehavior,
    ReventlessInfra.NoEventMappings.Make(Category),
  )

  module CategoryProjections: Mappings with module Target := CategoriesReadModel = {
    module M = Mappings.Make(CategoriesReadModel)
    module type Mapping = M.Mapping
    let mappings: array<module(Mapping)> = [module(CategoriesProjections.CategoryMapping)]
  }

  module CategoryReadModel = Platform.ReadModel.Make(CategoriesReadModel, CategoryProjections)

  // ── Product/ProductDemand DCB ───────────────────────────────
  module CatalogEventLogMaker = Platform.DcbEventLog.Make(CatalogEventLog)

  module AddProductSlice = Platform.StateChangeSlice.Make(AddProduct)
  module ChangeProductNameSlice = Platform.StateChangeSlice.Make(ChangeProductName)
  module ChangeProductDescriptionSlice = Platform.StateChangeSlice.Make(ChangeProductDescription)
  module ChangeProductPriceSlice = Platform.StateChangeSlice.Make(ChangeProductPrice)

  module ProductsViewSlice = Platform.StateViewSlice.Make(ProductsView)

  module ImportProductSlice = Platform.InboundTranslationSlice.Make(ImportProduct)

  module RecordProductDemandSlice = Platform.StateChangeSlice.Make(RecordProductDemand)
  module ProductDemandViewSlice = Platform.StateViewSlice.Make(ProductDemandView)

  // ── Extension Point (outbound) ──────────────────────────────
  module ProductsEPMappingT = ReventlessInfra.ExtensionPointMapping.Make(
    CatalogSpec.ProductsExtensionPoint,
    ProductsExtensionPointMapping,
  )
  module ProductsEPMappings = {
    module Spec = CatalogSpec.ProductsExtensionPoint
    module type Mapping = ReventlessInfra.ExtensionPointMapping.T with module ExtensionPoint := Spec
    let mappings: array<module(Mapping)> = [module(ProductsEPMappingT)]
  }
  module ProductsExtensionPointMaker = Platform.ExtensionPoint.Make(
    CatalogSpec.ProductsExtensionPoint,
    ProductsEPMappings,
  )

  // ── Extension (inbound from Ordering) ───────────────────────
  module OrdersDemandMapping = ReventlessInfra.ExtensionMapping.Make(
    OrderingSpec.OrdersExtensionPoint,
    OrdersExtension.DemandMapping,
  )
  module OrdersExtensionMappings = {
    module Spec = OrderingSpec.OrdersExtensionPoint
    module type Mapping = ReventlessInfra.ExtensionMapping.T
      with module ExtensionPoint := Spec
    let name = "CatalogDemand"
    let mappings: array<module(Mapping)> = [module(OrdersDemandMapping)]
  }
  module OrdersExtensionMaker = Platform.Extension.Make(
    OrderingSpec.OrdersExtensionPoint,
    OrdersExtensionMappings,
  )

  // ── DCB Spec (excludes Category — it's an aggregate) ───────
  module DcbSpec = {
    @schema
    type event = CatalogEventLog.event
    let stateChangeSlices: array<
      module(ReventlessInfra.StateChangeSlice.T with type dcbEvent = event),
    > = [
      module(AddProductSlice),
      module(ChangeProductNameSlice),
      module(ChangeProductDescriptionSlice),
      module(ChangeProductPriceSlice),
      module(RecordProductDemandSlice),
    ]
    let stateViewSlices: array<
      module(ReventlessInfra.StateViewSlice.T with type dcbEvent = event),
    > = [
      module(ProductsViewSlice),
      module(ProductDemandViewSlice),
    ]
    let automationSlices: array<
      module(ReventlessInfra.AutomationSlice.T with type dcbEvent = event),
    > = []
    let outboundTranslationSlices: array<
      module(ReventlessInfra.OutboundTranslationSlice.T with type dcbEvent = event),
    > = []
    let inboundTranslationSlices: array<
      module(ReventlessInfra.InboundTranslationSlice.T with type dcbEvent = event),
    > = [module(ImportProductSlice)]
  }

  // ── Hybrid Plugin Assembly ──────────────────────────────────
  let make = (
    ~scheduler: Pulumi.Output.t<ReventlessInfra.Scheduler.operations>,
    ~api: Platform.api,
    ~apiRole: Platform.role,
  ) =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~version="1.0.0",
      ~heartbeatInterval=60,
      ~aggregates=[module(CategoryAggregate)],
      ~readModels=[module(CategoryReadModel)],
      ~extensionPoints=[module(ProductsExtensionPointMaker)],
      ~extensions=[module(OrdersExtensionMaker)],
      ~api,
      ~apiRole,
      ~scheduler,
      ~dcbSpec=module(DcbSpec),
    )
}
