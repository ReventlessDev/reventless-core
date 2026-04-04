// Catalog DCB plugin — platform-agnostic composition root.
// Wires the shared event log, all StateChangeSlices, StateViewSlices, the
// ProductsExtensionPoint (outbound), and the OrdersExtension (inbound).

module Make = (Platform: ReventlessInfra.Platform.T) => {
  module AddProductSlice = Platform.StateChangeSlice.Make(AddProduct)
  module ChangeProductNameSlice = Platform.StateChangeSlice.Make(ChangeProductName)
  module ChangeProductDescriptionSlice = Platform.StateChangeSlice.Make(ChangeProductDescription)
  module ChangeProductPriceSlice = Platform.StateChangeSlice.Make(ChangeProductPrice)

  module ProductsViewSlice = Platform.StateViewSlice.Make(ProductsView)

  module AddCategorySlice = Platform.StateChangeSlice.Make(AddCategory)
  module RenameCategorySlice = Platform.StateChangeSlice.Make(RenameCategory)
  module ArchiveCategorySlice = Platform.StateChangeSlice.Make(ArchiveCategory)

  module CategoriesViewSlice = Platform.StateViewSlice.Make(CategoriesView)

  module ImportProductSlice = Platform.InboundTranslationSlice.Make(ImportProduct)

  // Demand tracking — driven by Ordering's OrdersExtensionPoint
  module RecordProductDemandSlice = Platform.StateChangeSlice.Make(RecordProductDemand)
  module ProductDemandViewSlice = Platform.StateViewSlice.Make(ProductDemandView)

  // Build the Products extension point component
  module ProductsExtensionPointMaker = Platform.ExtensionPoint.Make(
    CatalogSpec.ProductsExtensionPoint,
    ProductsExtensionPointMapping,
    {let moduleUrl: string = %raw(`import.meta.url`)},
  )

  // Build the Orders extension (subscribing to Ordering's EP)
  module OrdersExtensionMaker = Platform.Extension.Make(
    OrderingSpec.OrdersExtensionPoint,
    OrdersExtension.DemandMapping,
  )

  // --- Self-assembly: produce a ready-to-use Plugin.component ---

  let make = () =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~heartbeatInterval=60,
      ~extensionPoints=[module(ProductsExtensionPointMaker)],
      ~extensions=[module(OrdersExtensionMaker)],
      ~stateChangeSlices=[
        module(AddProductSlice),
        module(ChangeProductNameSlice),
        module(ChangeProductDescriptionSlice),
        module(ChangeProductPriceSlice),
        module(AddCategorySlice),
        module(RenameCategorySlice),
        module(ArchiveCategorySlice),
        module(RecordProductDemandSlice),
      ],
      ~stateViewSlices=[
        module(ProductsViewSlice),
        module(CategoriesViewSlice),
        module(ProductDemandViewSlice),
      ],
      ~inboundTranslationSlices=[module(ImportProductSlice)],
    )
}
