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
    let moduleUrl: string = %raw(`import.meta.url`)
    let mappings: array<module(Mapping)> = [module(CategoriesProjections.CategoryMapping)]
  }

  module CategoryReadModel = Platform.ReadModel.Make(CategoriesReadModel, CategoryProjections)

  // ── Product/ProductDemand DCB ───────────────────────────────
  module AddProductSlice = Platform.StateChangeSlice.Make(AddProduct)
  module ChangeProductNameSlice = Platform.StateChangeSlice.Make(ChangeProductName)
  module ChangeProductDescriptionSlice = Platform.StateChangeSlice.Make(ChangeProductDescription)
  module ChangeProductPriceSlice = Platform.StateChangeSlice.Make(ChangeProductPrice)

  module ProductsViewSlice = Platform.StateViewSlice.Make(ProductsView)

  module ImportProductSlice = Platform.InboundTranslationSlice.Make(ImportProduct)

  module RecordProductDemandSlice = Platform.StateChangeSlice.Make(RecordProductDemand)
  module ProductDemandViewSlice = Platform.StateViewSlice.Make(ProductDemandView)

  // ── Extension Point (outbound) ──────────────────────────────
  module ProductsExtensionPointMaker = Platform.ExtensionPoint.Make(
    ProductsExtensionPointMapping,
    {let moduleUrl: string = %raw(`import.meta.url`)},
  )

  // ── Extension (inbound from Ordering) ───────────────────────
  module OrdersExtensionMaker = Platform.Extension.Make(
    OrdersExtension.DemandMapping,
  )

  // ── Hybrid Plugin Assembly ──────────────────────────────────
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
