// AUTO-GENERATED — do not edit. Run `npm run generate` to update.

@val external uiBundleUrl: option<string> = "process.env.CATALOG_UI_BUNDLE_URL"

module Make = (Platform: ReventlessInfra.Platform.T) => {
  // StateChangeSlices
  module AddCategorySlice = Platform.StateChangeSlice.Make(AddCategory, AddCategory_Behavior)
  module AddProductSlice = Platform.StateChangeSlice.Make(AddProduct, AddProduct_Behavior)
  module ArchiveCategorySlice = Platform.StateChangeSlice.Make(ArchiveCategory, ArchiveCategory_Behavior)
  module ArchiveProductSlice = Platform.StateChangeSlice.Make(ArchiveProduct, ArchiveProduct_Behavior)
  module ChangeCategoryImageSlice = Platform.StateChangeSlice.Make(ChangeCategoryImage, ChangeCategoryImage_Behavior)
  module ChangeProductDescriptionSlice = Platform.StateChangeSlice.Make(ChangeProductDescription, ChangeProductDescription_Behavior)
  module ChangeProductImageSlice = Platform.StateChangeSlice.Make(ChangeProductImage, ChangeProductImage_Behavior)
  module ChangeProductNameSlice = Platform.StateChangeSlice.Make(ChangeProductName, ChangeProductName_Behavior)
  module ChangeProductPriceSlice = Platform.StateChangeSlice.Make(ChangeProductPrice, ChangeProductPrice_Behavior)
  module DiscontinueProductSlice = Platform.StateChangeSlice.Make(DiscontinueProduct, DiscontinueProduct_Behavior)
  module RecordProductDemandSlice = Platform.StateChangeSlice.Make(RecordProductDemand, RecordProductDemand_Behavior)
  module RenameCategorySlice = Platform.StateChangeSlice.Make(RenameCategory, RenameCategory_Behavior)
  module UnarchiveCategorySlice = Platform.StateChangeSlice.Make(UnarchiveCategory, UnarchiveCategory_Behavior)
  module UnarchiveProductSlice = Platform.StateChangeSlice.Make(UnarchiveProduct, UnarchiveProduct_Behavior)

  // StateViewSliceStreams
  module CategoriesStreamSlice = Platform.StateViewSliceStream.Make(Categories, Categories_Projection)
  module ProductDemandStreamSlice = Platform.StateViewSliceStream.Make(ProductDemand, ProductDemand_Projection)
  module ProductsStreamSlice = Platform.StateViewSliceStream.Make(Products, Products_Projection)

  // InboundTranslationSlices
  module ImportProductSlice = Platform.InboundTranslationSlice.Make(ImportProduct, ImportProduct_Translation)

  // Tasks
  module ImportProductsTask = Platform.Task.Make(ImportProducts)

  // ExtensionPoints
  module Products_ExtensionPoint = Platform.ExtensionPoint.Make(Products_ExtensionPointMapping)

  // Extensions
  module Orders_Extension = Platform.Extension.Make(Orders_Extension.Mapping)

  let pluginStructure = Platform.Plugin.makePluginDefinition(
    ~name="Catalog",
    ~stateViewSlices=[module(CategoriesStreamSlice), module(ProductDemandStreamSlice), module(ProductsStreamSlice)],
    ~stateChangeSlices=[module(AddCategorySlice), module(AddProductSlice), module(ArchiveCategorySlice), module(ArchiveProductSlice), module(ChangeCategoryImageSlice), module(ChangeProductDescriptionSlice), module(ChangeProductImageSlice), module(ChangeProductNameSlice), module(ChangeProductPriceSlice), module(DiscontinueProductSlice), module(RecordProductDemandSlice), module(RenameCategorySlice), module(UnarchiveCategorySlice), module(UnarchiveProductSlice)],
    ~inboundTranslationSlices=[module(ImportProductSlice)],
    ~extensions=[module(Orders_Extension)],
    ~extensionPoints=[module(Products_ExtensionPointMapping)],
    ~componentChapters=Dict.fromArray([("AddCategory", "Category"), ("AddProduct", "Product"), ("ArchiveCategory", "Category"), ("ArchiveProduct", "Product"), ("Categories", "Category"), ("ChangeCategoryImage", "Category"), ("ChangeProductDescription", "Product"), ("ChangeProductImage", "Product"), ("ChangeProductName", "Product"), ("ChangeProductPrice", "Product"), ("DiscontinueProduct", "Product"), ("ImportProduct", "Product"), ("ProductDemand", "Product"), ("Products", "Product"), ("RecordProductDemand", "ProductDemand"), ("RenameCategory", "Category"), ("UnarchiveCategory", "Category"), ("UnarchiveProduct", "Product")]),
  )

  let make = () =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~heartbeatInterval=5,
      ~extensionPoints=[module(Products_ExtensionPoint)],
      ~extensions=[module(Orders_Extension)],
      ~tasks=[module(ImportProductsTask)],
      ~stateChangeSlices=[module(AddCategorySlice), module(AddProductSlice), module(ArchiveCategorySlice), module(ArchiveProductSlice), module(ChangeCategoryImageSlice), module(ChangeProductDescriptionSlice), module(ChangeProductImageSlice), module(ChangeProductNameSlice), module(ChangeProductPriceSlice), module(DiscontinueProductSlice), module(RecordProductDemandSlice), module(RenameCategorySlice), module(UnarchiveCategorySlice), module(UnarchiveProductSlice)],
      ~stateViewSlices=[module(CategoriesStreamSlice), module(ProductDemandStreamSlice), module(ProductsStreamSlice)],
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
