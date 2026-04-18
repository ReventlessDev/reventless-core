// Catalog plugin — AWS deployment.
// Uses direct AWS builders for Aggregate and ReadModel components.
// DCB slices, ExtensionPoints, and Extensions use standard Platform builders.

open Reventless.Projection

// DCB config registered in index.mjs (before ReScript module init)

module Make = (
  Platform: ReventlessInfra.Platform.T
    with type api = ReventlessAws.Types.AppSync.api
    and type role = ReventlessAws.Types.AppSync.role,
) => {
  // ── Category Aggregate ────────────────────────────────────────
  module CategoryAggregate = ReventlessAws.Aggregate_Builder_Single.Make(
    CatalogPlugin.Category,
    CatalogPlugin.CategoryBehavior,
    ReventlessInfra.NoEventMappings.Make(CatalogPlugin.Category),
  )

  // ── Categories ReadModel ──────────────────────────────────────
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
  module AddProductSlice = Platform.StateChangeSlice.Make(CatalogPlugin.AddProduct)
  module ChangeProductNameSlice = Platform.StateChangeSlice.Make(CatalogPlugin.ChangeProductName)
  module ChangeProductDescriptionSlice = Platform.StateChangeSlice.Make(
    CatalogPlugin.ChangeProductDescription,
  )
  module ChangeProductPriceSlice = Platform.StateChangeSlice.Make(CatalogPlugin.ChangeProductPrice)
  module RecordProductDemandSlice = Platform.StateChangeSlice.Make(
    CatalogPlugin.RecordProductDemand,
  )

  // Stream-enabled: allows StateTopic_AppSync to push state changes via AppSync Events API.
  module ProductsViewSlice = Platform.StateViewSliceStream.Make(CatalogPlugin.ProductsView)
  module ProductDemandViewSlice = Platform.StateViewSliceStream.Make(
    CatalogPlugin.ProductDemandView,
  )

  module ImportProductSlice = Platform.InboundTranslationSlice.Make(CatalogPlugin.ImportProduct)

  // ── Extension Point ───────────────────────────────────────────
  module ProductsEPMappingT = ReventlessInfra.ExtensionPointMapping.Make(
    CatalogPlugin.ProductsExtensionPointMapping,
  )
  module ProductsEPMappings = {
    module Spec = CatalogPlugin.ProductsExtensionPointMapping.ExtensionPoint
    module type Mapping = ReventlessInfra.ExtensionPointMapping.T with module ExtensionPoint := Spec
    let name = "ProductsEPMappings"
    let moduleUrl: string = %raw(`import.meta.url`)
    let mappings: array<module(Mapping)> = [module(ProductsEPMappingT)]
  }
  module ProductsExtensionPointMaker = ReventlessAws.ExtensionPoint_Builder.Make(
    ProductsEPMappings.Spec,
    ProductsEPMappings,
    {
      let publishToAggregatesQueueUrls = Dict.make()
    },
  )

  // ── Extension (standard — via Platform) ──────────────────────
  module OrdersExtensionMaker = Platform.Extension.Make(
    CatalogPlugin.OrdersExtension.Mapping,
  )

  // ── Hybrid Plugin Assembly ───────────────────────────────────
  let make = () =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~heartbeatInterval=60,
      ~aggregates=[module(CategoryAggregate)],
      ~readModels=[module(CategoryReadModel)],
      ~extensionPoints=[module(ProductsExtensionPointMaker)],
      ~extensions=[module(OrdersExtensionMaker)],
      ~stateChangeSlices=[
        module(AddProductSlice),
        module(ChangeProductNameSlice),
        module(ChangeProductDescriptionSlice),
        module(ChangeProductPriceSlice),
        module(RecordProductDemandSlice),
      ],
      ~stateViewSlices=[
        module(ProductsViewSlice),
        module(ProductDemandViewSlice),
      ],
      ~inboundTranslationSlices=[module(ImportProductSlice)],
    )
}
