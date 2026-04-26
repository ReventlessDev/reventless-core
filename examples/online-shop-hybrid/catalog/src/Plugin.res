// AUTO-GENERATED — do not edit. Run `npm run generate` to update.
open Reventless.Projection

module Make = (Platform: ReventlessInfra.Platform.T) => {
  // StateChangeSlices
  module AddProductSlice = Platform.StateChangeSlice.Make(AddProduct, AddProduct_Behavior)
  module ChangeProductDescriptionSlice = Platform.StateChangeSlice.Make(ChangeProductDescription, ChangeProductDescription_Behavior)
  module ChangeProductNameSlice = Platform.StateChangeSlice.Make(ChangeProductName, ChangeProductName_Behavior)
  module ChangeProductPriceSlice = Platform.StateChangeSlice.Make(ChangeProductPrice, ChangeProductPrice_Behavior)
  module RecordProductDemandSlice = Platform.StateChangeSlice.Make(RecordProductDemand, RecordProductDemand_Behavior)

  // StateViewSliceStreams
  module ProductDemandViewStreamSlice = Platform.StateViewSliceStream.Make(ProductDemandView, ProductDemandView_Projection)
  module ProductsViewStreamSlice = Platform.StateViewSliceStream.Make(ProductsView, ProductsView_Projection)

  // InboundTranslationSlices
  module ImportProductSlice = Platform.InboundTranslationSlice.Make(ImportProduct, ImportProduct_Translation)

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

  // Tasks
  module ImportProductsTask = Platform.Task.Make(ImportProducts)

  // ExtensionPoints
  module ProductsExtensionPointMaker = Platform.ExtensionPoint.Make(ProductsExtensionPointMapping)

  // Extensions
  module OrdersExtensionMaker = Platform.Extension.Make(OrdersExtension.Mapping)

  let pluginStructure = Platform.Plugin.makePluginDefinition(
    ~name="Catalog",
    ~aggregates=[module(CategoryAggregate)],
    ~readModels=[module(CategoriesReadModelMaker)],
    ~stateViewSlices=[module(ProductDemandViewStreamSlice), module(ProductsViewStreamSlice)],
    ~stateChangeSlices=[module(AddProductSlice), module(ChangeProductDescriptionSlice), module(ChangeProductNameSlice), module(ChangeProductPriceSlice), module(RecordProductDemandSlice)],
    ~inboundTranslationSlices=[module(ImportProductSlice)],
    ~extensions=[module(OrdersExtensionMaker)],
  )

  let make = (~uiBundleUrl=?) =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~heartbeatInterval=60,
      ~extensionPoints=[module(ProductsExtensionPointMaker)],
      ~extensions=[module(OrdersExtensionMaker)],
      ~aggregates=[module(CategoryAggregate)],
      ~readModels=[module(CategoriesReadModelMaker)],
      ~tasks=[module(ImportProductsTask)],
      ~stateChangeSlices=[module(AddProductSlice), module(ChangeProductDescriptionSlice), module(ChangeProductNameSlice), module(ChangeProductPriceSlice), module(RecordProductDemandSlice)],
      ~stateViewSlices=[module(ProductDemandViewStreamSlice), module(ProductsViewStreamSlice)],
      ~inboundTranslationSlices=[module(ImportProductSlice)],
      ~pluginStructure=pluginStructure,
      ~uiFragments=?uiBundleUrl->Option.map(url =>
        Platform.Plugin.makeAutoUIManifest(
          ~remoteEntryUrl=url,
          ~name="Catalog",
          ~aggregates=[module(CategoryAggregate)],
          ~readModels=[module(CategoriesReadModelMaker)],
          ~readModelPositions=["platform-summary"],
          ~aggregatePositions=["resource-detail"],
        )
      ),
    )
}
