// Catalog plugin — bundled variant for AWS deployment.
// Uses bundled Lambda handlers for Aggregate and ReadModel components.
// DCB slices, ExtensionPoints, and Extensions use standard Platform builders.

open Reventless.Projection

// DCB config registered in index.mjs (before ReScript module init)

module Make = (
  Platform: ReventlessInfra.Platform.T
    with type api = ReventlessAws.Types.AppSync.api
    and type role = ReventlessAws.Types.AppSync.role,
) => {
  // ── Category Aggregate (BUNDLED) ─────────────────────────────
  module CategoryAggregate = ReventlessAws.Aggregate_Builder_Single.Make(
    CatalogPlugin.Category,
    CatalogPlugin.CategoryBehavior,
    ReventlessInfra.NoEventMappings.Make(CatalogPlugin.Category),
  )

  // ── Categories ReadModel (BUNDLED) ───────────────────────────
  module CategoryProjections: Mappings with module Target := CatalogPlugin.CategoriesReadModel = {
    module M = Mappings.Make(CatalogPlugin.CategoriesReadModel)
    module type Mapping = M.Mapping
    let moduleUrl: string = %raw(`import.meta.url`)
    let mappings: array<module(Mapping)> = [
      module(CatalogPlugin.CategoriesProjections.CategoryMapping),
    ]
  }

  module CategoryReadModel = ReventlessAws.ReadModel_Builder_Single.Make(
    CatalogPlugin.CategoriesReadModel,
    CategoryProjections,
  )

  // ── Product/ProductDemand DCB (standard — via Platform) ──────
  module CatalogEventLogMaker = Platform.DcbEventLog.Make(CatalogPlugin.CatalogEventLog)

  module AddProductSlice = Platform.StateChangeSlice.Make(CatalogPlugin.AddProduct)
  module ChangeProductNameSlice = Platform.StateChangeSlice.Make(CatalogPlugin.ChangeProductName)
  module ChangeProductDescriptionSlice = Platform.StateChangeSlice.Make(
    CatalogPlugin.ChangeProductDescription,
  )
  module ChangeProductPriceSlice = Platform.StateChangeSlice.Make(CatalogPlugin.ChangeProductPrice)
  module RecordProductDemandSlice = Platform.StateChangeSlice.Make(
    CatalogPlugin.RecordProductDemand,
  )

  module ProductsViewSlice = Platform.StateViewSlice.Bundled.Make(CatalogPlugin.ProductsView)
  module ProductDemandViewSlice = Platform.StateViewSlice.Bundled.Make(
    CatalogPlugin.ProductDemandView,
  )

  module ImportProductSlice = Platform.InboundTranslationSlice.Make(CatalogPlugin.ImportProduct)

  // ── Extension Point (BUNDLED) ────────────────────────────────
  module ProductsEPMappingT = ReventlessInfra.ExtensionPointMapping.Make(
    CatalogSpec.ProductsExtensionPoint,
    CatalogPlugin.ProductsExtensionPointMapping,
  )
  module ProductsEPMappings = {
    module Spec = CatalogSpec.ProductsExtensionPoint
    module type Mapping = ReventlessInfra.ExtensionPointMapping.T with module ExtensionPoint := Spec
    let name = "ProductsEPMappings"
    let moduleUrl: string = %raw(`import.meta.url`)
    let mappings: array<module(Mapping)> = [module(ProductsEPMappingT)]
  }
  module ProductsExtensionPointMaker = ReventlessAws.ExtensionPoint_Builder.Make(
    CatalogSpec.ProductsExtensionPoint,
    ProductsEPMappings,
    {
      let publishToAggregatesQueueUrls = Dict.make()
    },
  )

  // ── Extension (standard — via Platform) ──────────────────────
  module OrdersDemandMapping = ReventlessInfra.ExtensionMapping.Make(
    OrderingSpec.OrdersExtensionPoint,
    CatalogPlugin.OrdersExtension.DemandMapping,
  )
  module OrdersExtensionMappings = {
    module Spec = OrderingSpec.OrdersExtensionPoint
    module type Mapping = ReventlessInfra.ExtensionMapping.T
      with module ExtensionPoint := Spec
    let name = "CatalogDemand"
    let moduleUrl: string = %raw(`import.meta.url`)
    let mappings: array<module(Mapping)> = [module(OrdersDemandMapping)]
  }
  module OrdersExtensionMaker = Platform.Extension.Make(
    OrderingSpec.OrdersExtensionPoint,
    OrdersExtensionMappings,
  )

  // ── DCB Spec ─────────────────────────────────────────────────
  module DcbSpec = {
    @schema
    type event = CatalogPlugin.CatalogEventLog.event
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
    > = [module(ProductsViewSlice), module(ProductDemandViewSlice)]
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

  // ── Hybrid Plugin Assembly ───────────────────────────────────
  let make = (~scheduler, ~api, ~apiRole) =>
    Platform.Plugin.make(
      ~name="Catalog",
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
