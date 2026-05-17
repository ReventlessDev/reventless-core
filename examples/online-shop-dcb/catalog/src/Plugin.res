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
  module CategoriesSlice = Platform.StateViewSlice.Make(Categories, Categories_Projection)
  module ProductDemandSlice = Platform.StateViewSlice.Make(ProductDemand, ProductDemand_Projection)
  module ProductsSlice = Platform.StateViewSlice.Make(Products, Products_Projection)

  // InboundTranslationSlices
  module ImportProductSlice = Platform.InboundTranslationSlice.Make(ImportProduct, ImportProduct_Translation)

  // ExtensionPoints
  module Products_ExtensionPoint = Platform.ExtensionPoint.Make(Products_ExtensionPointMapping)

  // Extensions
  module Orders_Extension = Platform.Extension.Make(Orders_Extension.Mapping)

  let pluginStructure = Platform.Plugin.makePluginDefinition(
    ~name="Catalog",
    ~stateViewSlices=[module(CategoriesSlice), module(ProductDemandSlice), module(ProductsSlice)],
    ~stateChangeSlices=[module(AddCategorySlice), module(AddProductSlice), module(ArchiveCategorySlice), module(ChangeProductDescriptionSlice), module(ChangeProductNameSlice), module(ChangeProductPriceSlice), module(RecordProductDemandSlice), module(RenameCategorySlice)],
    ~inboundTranslationSlices=[module(ImportProductSlice)],
    ~extensions=[module(Orders_Extension)],
  )

  let make = () =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~heartbeatInterval=5,
      ~extensionPoints=[module(Products_ExtensionPoint)],
      ~extensions=[module(Orders_Extension)],
      ~stateChangeSlices=[module(AddCategorySlice), module(AddProductSlice), module(ArchiveCategorySlice), module(ChangeProductDescriptionSlice), module(ChangeProductNameSlice), module(ChangeProductPriceSlice), module(RecordProductDemandSlice), module(RenameCategorySlice)],
      ~stateViewSlices=[module(CategoriesSlice), module(ProductDemandSlice), module(ProductsSlice)],
      ~inboundTranslationSlices=[module(ImportProductSlice)],
      ~pluginStructure=pluginStructure,
    )
}
