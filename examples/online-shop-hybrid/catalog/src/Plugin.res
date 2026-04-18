// AUTO-GENERATED — do not edit. Run `npm run generate` to update.
open Reventless.Projection

module Make = (Platform: ReventlessInfra.Platform.T) => {
  // StateChangeSlices
  module AddProductSlice = Platform.StateChangeSlice.Make(AddProduct)
  module ChangeProductDescriptionSlice = Platform.StateChangeSlice.Make(ChangeProductDescription)
  module ChangeProductNameSlice = Platform.StateChangeSlice.Make(ChangeProductName)
  module ChangeProductPriceSlice = Platform.StateChangeSlice.Make(ChangeProductPrice)
  module RecordProductDemandSlice = Platform.StateChangeSlice.Make(RecordProductDemand)

  // StateViewSlices
  module ProductDemandViewSlice = Platform.StateViewSlice.Make(ProductDemandView)
  module ProductsViewSlice = Platform.StateViewSlice.Make(ProductsView)

  // InboundTranslationSlices
  module ImportProductSlice = Platform.InboundTranslationSlice.Make(ImportProduct)

  // Aggregates
  module CategoryAggregate = Platform.Aggregate.Make(
    Category,
    CategoryBehavior,
    ReventlessInfra.NoEventMappings.Make(Category),
  )

  // ReadModels
  @reventless.projections
  module CategoriesProjectionsWrapper: Mappings with module Target := CategoriesReadModel = {
    let mappings: array<module(Mapping)> = [module(CategoriesProjections.CategoryMapping)]
  }
  module CategoriesReadModelMaker = Platform.ReadModel.Make(CategoriesReadModel, CategoriesProjectionsWrapper)

  // ExtensionPoints
  module ProductsExtensionPointMaker = Platform.ExtensionPoint.Make(ProductsExtensionPointMapping)

  // Extensions
  module OrdersExtensionMaker = Platform.Extension.Make(OrdersExtension.Mapping)

  let uiDefinition = Platform.Plugin.makeAutoUIDefinition(
    ~name="Catalog",
    ~aggregates=[module(CategoryAggregate)],
    ~readModels=[module(CategoriesReadModelMaker)],
    ~stateViewSlices=[module(ProductDemandViewSlice), module(ProductsViewSlice)],
    ~stateChangeSlices=[module(AddProductSlice), module(ChangeProductDescriptionSlice), module(ChangeProductNameSlice), module(ChangeProductPriceSlice), module(RecordProductDemandSlice)],
  )

  let make = () =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~heartbeatInterval=60,
      ~extensionPoints=[module(ProductsExtensionPointMaker)],
      ~extensions=[module(OrdersExtensionMaker)],
      ~aggregates=[module(CategoryAggregate)],
      ~readModels=[module(CategoriesReadModelMaker)],
      ~stateChangeSlices=[module(AddProductSlice), module(ChangeProductDescriptionSlice), module(ChangeProductNameSlice), module(ChangeProductPriceSlice), module(RecordProductDemandSlice)],
      ~stateViewSlices=[module(ProductDemandViewSlice), module(ProductsViewSlice)],
      ~inboundTranslationSlices=[module(ImportProductSlice)],
      ~uiDefinition=uiDefinition,
    )
}
