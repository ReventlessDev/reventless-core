// AUTO-GENERATED — do not edit. Run `npm run generate` to update.
module Make = (Platform: ReventlessInfra.Platform.T) => {
  // StateChangeSlices
  module AddCategorySlice = Platform.StateChangeSlice.Make(AddCategory, AddCategory_Behavior)
  module AddProductSlice = Platform.StateChangeSlice.Make(AddProduct, AddProduct_Behavior)
  module ArchiveCategorySlice = Platform.StateChangeSlice.Make(ArchiveCategory, ArchiveCategory_Behavior)
  module ChangeProductDescriptionSlice = Platform.StateChangeSlice.Make(ChangeProductDescription, ChangeProductDescription_Behavior)
  module ChangeProductNameSlice = Platform.StateChangeSlice.Make(ChangeProductName, ChangeProductName_Behavior)
  module ChangeProductPriceSlice = Platform.StateChangeSlice.Make(ChangeProductPrice, ChangeProductPrice_Behavior)
  module RecordProductDemandSlice = Platform.StateChangeSlice.Make(RecordProductDemand, RecordProductDemand_Behavior)
  module RenameCategorySlice = Platform.StateChangeSlice.Make(RenameCategory, RenameCategory_Behavior)

  // StateViewSlices
  module CategoriesViewSlice = Platform.StateViewSlice.Make(CategoriesView, CategoriesView_Projection)
  module ProductDemandViewSlice = Platform.StateViewSlice.Make(ProductDemandView, ProductDemandView_Projection)
  module ProductsViewSlice = Platform.StateViewSlice.Make(ProductsView, ProductsView_Projection)

  // InboundTranslationSlices
  module ImportProductSlice = Platform.InboundTranslationSlice.Make(ImportProduct, ImportProduct_Translation)

  // ExtensionPoints
  module ProductsExtensionPoint = Platform.ExtensionPoint.Make(ProductsExtensionPointMapping)

  // Extensions
  module OrdersExtension = Platform.Extension.Make(OrdersExtension.Mapping)

  let pluginStructure = Platform.Plugin.makePluginDefinition(
    ~name="Catalog",
    ~stateViewSlices=[module(CategoriesViewSlice), module(ProductDemandViewSlice), module(ProductsViewSlice)],
    ~stateChangeSlices=[module(AddCategorySlice), module(AddProductSlice), module(ArchiveCategorySlice), module(ChangeProductDescriptionSlice), module(ChangeProductNameSlice), module(ChangeProductPriceSlice), module(RecordProductDemandSlice), module(RenameCategorySlice)],
    ~inboundTranslationSlices=[module(ImportProductSlice)],
    ~extensions=[module(OrdersExtension)],
  )

  let make = () =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~heartbeatInterval=60,
      ~extensionPoints=[module(ProductsExtensionPoint)],
      ~extensions=[module(OrdersExtension)],
      ~stateChangeSlices=[module(AddCategorySlice), module(AddProductSlice), module(ArchiveCategorySlice), module(ChangeProductDescriptionSlice), module(ChangeProductNameSlice), module(ChangeProductPriceSlice), module(RecordProductDemandSlice), module(RenameCategorySlice)],
      ~stateViewSlices=[module(CategoriesViewSlice), module(ProductDemandViewSlice), module(ProductsViewSlice)],
      ~inboundTranslationSlices=[module(ImportProductSlice)],
      ~pluginStructure=pluginStructure,
    )
}
