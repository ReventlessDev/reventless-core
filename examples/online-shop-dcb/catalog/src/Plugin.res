// AUTO-GENERATED — do not edit. Run `npm run generate` to update.

@val external uiBundleUrl: option<string> = "process.env.CATALOG_UI_BUNDLE_URL"

let dcbSliceSchemas: array<Reventless.DcbTag.sliceSchemas> = [
  {name: AddCategory.name, commandSchema: AddCategory.commandSchema->S.castToUnknown, consumedEventSchema: AddCategory.consumedEventSchema->S.castToUnknown, eventSchema: AddCategory.eventSchema->S.castToUnknown},
  {name: AddProduct.name, commandSchema: AddProduct.commandSchema->S.castToUnknown, consumedEventSchema: AddProduct.consumedEventSchema->S.castToUnknown, eventSchema: AddProduct.eventSchema->S.castToUnknown},
  {name: ArchiveCategory.name, commandSchema: ArchiveCategory.commandSchema->S.castToUnknown, consumedEventSchema: ArchiveCategory.consumedEventSchema->S.castToUnknown, eventSchema: ArchiveCategory.eventSchema->S.castToUnknown},
  {name: ChangeProductDescription.name, commandSchema: ChangeProductDescription.commandSchema->S.castToUnknown, consumedEventSchema: ChangeProductDescription.consumedEventSchema->S.castToUnknown, eventSchema: ChangeProductDescription.eventSchema->S.castToUnknown},
  {name: ChangeProductName.name, commandSchema: ChangeProductName.commandSchema->S.castToUnknown, consumedEventSchema: ChangeProductName.consumedEventSchema->S.castToUnknown, eventSchema: ChangeProductName.eventSchema->S.castToUnknown},
  {name: ChangeProductPrice.name, commandSchema: ChangeProductPrice.commandSchema->S.castToUnknown, consumedEventSchema: ChangeProductPrice.consumedEventSchema->S.castToUnknown, eventSchema: ChangeProductPrice.eventSchema->S.castToUnknown},
  {name: RecordProductDemand.name, commandSchema: RecordProductDemand.commandSchema->S.castToUnknown, consumedEventSchema: RecordProductDemand.consumedEventSchema->S.castToUnknown, eventSchema: RecordProductDemand.eventSchema->S.castToUnknown},
  {name: RenameCategory.name, commandSchema: RenameCategory.commandSchema->S.castToUnknown, consumedEventSchema: RenameCategory.consumedEventSchema->S.castToUnknown, eventSchema: RenameCategory.eventSchema->S.castToUnknown},
]

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

  // ReadModels
  module CategoryActivityReadModel = Platform.ReadModel.Make(CategoryActivity, CategoryActivity_Projections)

  // Tasks
  module ImportProductsTask = Platform.Task.Make(ImportProducts)

  // ExtensionPoints
  module Products_ExtensionPoint = Platform.ExtensionPoint.Make(Products_ExtensionPointMapping)

  // Extensions
  module Orders_Extension = Platform.Extension.Make(Orders_Extension.Mapping)

  let pluginStructure = Platform.Plugin.makePluginDefinition(
    ~name="Catalog",
    ~readModels=[module(CategoryActivityReadModel)],
    ~stateViewSlices=[module(CategoriesSlice), module(ProductDemandSlice), module(ProductsSlice)],
    ~stateChangeSlices=[module(AddCategorySlice), module(AddProductSlice), module(ArchiveCategorySlice), module(ChangeProductDescriptionSlice), module(ChangeProductNameSlice), module(ChangeProductPriceSlice), module(RecordProductDemandSlice), module(RenameCategorySlice)],
    ~inboundTranslationSlices=[module(ImportProductSlice)],
    ~extensions=[module(Orders_Extension)],
    ~extensionPoints=[module(Products_ExtensionPointMapping)],
    ~componentChapters=Dict.fromArray([("AddCategory", "Category"), ("AddProduct", "Product"), ("ArchiveCategory", "Category"), ("Categories", "Category"), ("CategoryActivity", "CategoryActivity"), ("ChangeProductDescription", "Product"), ("ChangeProductName", "Product"), ("ChangeProductPrice", "Product"), ("ImportProduct", "Product"), ("ProductDemand", "ProductDemand"), ("Products", "Product"), ("RecordProductDemand", "ProductDemand"), ("RenameCategory", "Category")]),
  )

  let make = () =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~heartbeatInterval=5,
      ~extensionPoints=[module(Products_ExtensionPoint)],
      ~extensions=[module(Orders_Extension)],
      ~readModels=[module(CategoryActivityReadModel)],
      ~tasks=[module(ImportProductsTask)],
      ~stateChangeSlices=[module(AddCategorySlice), module(AddProductSlice), module(ArchiveCategorySlice), module(ChangeProductDescriptionSlice), module(ChangeProductNameSlice), module(ChangeProductPriceSlice), module(RecordProductDemandSlice), module(RenameCategorySlice)],
      ~stateViewSlices=[module(CategoriesSlice), module(ProductDemandSlice), module(ProductsSlice)],
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
