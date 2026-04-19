// AUTO-GENERATED — do not edit. Run `npm run generate` to update.
module Make = (Platform: ReventlessInfra.Platform.T) => {
  // StateChangeSlices
  module AddCategorySlice = Platform.StateChangeSlice.Make(AddCategory)
  module AddProductSlice = Platform.StateChangeSlice.Make(AddProduct)
  module ArchiveCategorySlice = Platform.StateChangeSlice.Make(ArchiveCategory)
  module ChangeProductDescriptionSlice = Platform.StateChangeSlice.Make(ChangeProductDescription)
  module ChangeProductNameSlice = Platform.StateChangeSlice.Make(ChangeProductName)
  module ChangeProductPriceSlice = Platform.StateChangeSlice.Make(ChangeProductPrice)
  module RecordProductDemandSlice = Platform.StateChangeSlice.Make(RecordProductDemand)
  module RenameCategorySlice = Platform.StateChangeSlice.Make(RenameCategory)

  // StateViewSlices
  module CategoriesViewSlice = Platform.StateViewSlice.Make(CategoriesView)
  module ProductDemandViewSlice = Platform.StateViewSlice.Make(ProductDemandView)
  module ProductsViewSlice = Platform.StateViewSlice.Make(ProductsView)

  // InboundTranslationSlices
  module ImportProductSlice = Platform.InboundTranslationSlice.Make(ImportProduct)

  // ExtensionPoints
  module ProductsExtensionPointMaker = Platform.ExtensionPoint.Make(ProductsExtensionPointMapping)

  // Extensions
  module OrdersExtensionMaker = Platform.Extension.Make(OrdersExtension.Mapping)

  let pluginStructure = Platform.Plugin.makePluginDefinition(
    ~name="Catalog",
    ~stateViewSlices=[module(CategoriesViewSlice), module(ProductDemandViewSlice), module(ProductsViewSlice)],
    ~stateChangeSlices=[module(AddCategorySlice), module(AddProductSlice), module(ArchiveCategorySlice), module(ChangeProductDescriptionSlice), module(ChangeProductNameSlice), module(ChangeProductPriceSlice), module(RecordProductDemandSlice), module(RenameCategorySlice)],
  )

  let make = () =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~heartbeatInterval=60,
      ~extensionPoints=[module(ProductsExtensionPointMaker)],
      ~extensions=[module(OrdersExtensionMaker)],
      ~stateChangeSlices=[module(AddCategorySlice), module(AddProductSlice), module(ArchiveCategorySlice), module(ChangeProductDescriptionSlice), module(ChangeProductNameSlice), module(ChangeProductPriceSlice), module(RecordProductDemandSlice), module(RenameCategorySlice)],
      ~stateViewSlices=[module(CategoriesViewSlice), module(ProductDemandViewSlice), module(ProductsViewSlice)],
      ~inboundTranslationSlices=[module(ImportProductSlice)],
      ~pluginStructure=pluginStructure,
    )
}
