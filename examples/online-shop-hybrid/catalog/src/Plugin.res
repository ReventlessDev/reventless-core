// AUTO-GENERATED — do not edit. Run `npm run generate` to update.

@val external uiBundleUrl: option<string> = "process.env.CATALOG_UI_BUNDLE_URL"

module Make = (Platform: ReventlessInfra.Platform.T) => {
  // StateChangeSlices
  module AddProductSlice = Platform.StateChangeSlice.Make(AddProduct, AddProduct_Behavior)
  module ChangeProductDescriptionSlice = Platform.StateChangeSlice.Make(ChangeProductDescription, ChangeProductDescription_Behavior)
  module ChangeProductNameSlice = Platform.StateChangeSlice.Make(ChangeProductName, ChangeProductName_Behavior)
  module ChangeProductPriceSlice = Platform.StateChangeSlice.Make(ChangeProductPrice, ChangeProductPrice_Behavior)
  module RecordProductDemandSlice = Platform.StateChangeSlice.Make(RecordProductDemand, RecordProductDemand_Behavior)

  // StateViewSliceStreams
  module ProductDemandStreamSlice = Platform.StateViewSliceStream.Make(ProductDemand, ProductDemand_Projection)
  module ProductsStreamSlice = Platform.StateViewSliceStream.Make(Products, Products_Projection)

  // InboundTranslationSlices
  module ImportProductSlice = Platform.InboundTranslationSlice.Make(ImportProduct, ImportProduct_Translation)

  // Aggregates
  module CategoryAggregate = Platform.Aggregate.Make(
    Category,
    Category_Behavior,
    ReventlessInfra.NoEventMappings.Make(Category),
  )

  // ReadModels
  module CatalogActivityReadModel = Platform.ReadModel.Make(CatalogActivity, CatalogActivity_Projections)
  module CategoriesReadModel = Platform.ReadModel.Make(Categories, Categories_Projections)

  // Tasks
  module ImportProductsTask = Platform.Task.Make(ImportProducts)

  // ExtensionPoints
  module Products_ExtensionPoint = Platform.ExtensionPoint.Make(Products_ExtensionPointMapping)

  // Extensions
  module Orders_Extension = Platform.Extension.Make(Orders_Extension.Mapping)

  let pluginStructure = Platform.Plugin.makePluginDefinition(
    ~name="Catalog",
    ~aggregates=[module(CategoryAggregate)],
    ~readModels=[module(CatalogActivityReadModel), module(CategoriesReadModel)],
    ~stateViewSlices=[module(ProductDemandStreamSlice), module(ProductsStreamSlice)],
    ~stateChangeSlices=[module(AddProductSlice), module(ChangeProductDescriptionSlice), module(ChangeProductNameSlice), module(ChangeProductPriceSlice), module(RecordProductDemandSlice)],
    ~inboundTranslationSlices=[module(ImportProductSlice)],
    ~extensions=[module(Orders_Extension)],
    ~extensionPoints=[module(Products_ExtensionPointMapping)],
  )

  let make = () =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~heartbeatInterval=5,
      ~extensionPoints=[module(Products_ExtensionPoint)],
      ~extensions=[module(Orders_Extension)],
      ~aggregates=[module(CategoryAggregate)],
      ~readModels=[module(CatalogActivityReadModel), module(CategoriesReadModel)],
      ~tasks=[module(ImportProductsTask)],
      ~stateChangeSlices=[module(AddProductSlice), module(ChangeProductDescriptionSlice), module(ChangeProductNameSlice), module(ChangeProductPriceSlice), module(RecordProductDemandSlice)],
      ~stateViewSlices=[module(ProductDemandStreamSlice), module(ProductsStreamSlice)],
      ~inboundTranslationSlices=[module(ImportProductSlice)],
      ~pluginStructure=pluginStructure,
      ~uiFragments=?uiBundleUrl->Option.map(url =>
        Platform.Plugin.makeAutoUIManifest(
          ~remoteEntryUrl=url,
          ~name="Catalog",
          ~pluginStructure,
          ~readModelPositions=["platform-summary"],
          ~aggregatePositions=["resource-detail"],
        )
      ),
    )
}
