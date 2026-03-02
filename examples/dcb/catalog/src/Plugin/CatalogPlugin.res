// Catalog DCB plugin — platform-agnostic composition root.
// Wires the shared event log, all StateChangeSlices, StateViewSlices, the
// ProductsExtensionPoint (outbound), and the OrdersExtension (inbound).

open Reventless
module Make = (Platform: Platform.T) => {
  module CatalogEventLogMaker = Platform.DcbEventLog.Make(CatalogEventLog)

  module AddProductSlice = Platform.StateChangeSlice.Make(AddProduct)
  module UpdateProductNameSlice = Platform.StateChangeSlice.Make(UpdateProductName)
  module UpdateProductDescriptionSlice = Platform.StateChangeSlice.Make(UpdateProductDescription)
  module UpdateProductPriceSlice = Platform.StateChangeSlice.Make(UpdateProductPrice)

  module ProductsViewSlice = Platform.StateViewSlice.Make(ProductsView)

  module AddCategorySlice = Platform.StateChangeSlice.Make(AddCategory)
  module RenameCategorySlice = Platform.StateChangeSlice.Make(RenameCategory)
  module ArchiveCategorySlice = Platform.StateChangeSlice.Make(ArchiveCategory)

  module CategoriesViewSlice = Platform.StateViewSlice.Make(CategoriesView)

  // Demand tracking — driven by Ordering's OrdersExtensionPoint
  module RecordProductDemandSlice = Platform.StateChangeSlice.Make(RecordProductDemand)
  module ProductDemandViewSlice = Platform.StateViewSlice.Make(ProductDemandView)

  // Compile the Products extension point mapping, then build the EP component
  module ProductsEPMappingT = ReventlessCore.ExtensionPointMapping.Make(
    ProductsExtensionPointSpec,
    ProductsExtensionPointMapping,
  )
  module ProductsEPMappings = {
    module Spec = ProductsExtensionPointSpec
    module type Mapping = ExtensionPointMapping.T with module ExtensionPoint := Spec
    let mappings: array<module(Mapping)> = [module(ProductsEPMappingT)]
  }
  module ProductsExtensionPointMaker = Platform.ExtensionPoint.Make(
    ProductsExtensionPointSpec,
    ProductsEPMappings,
  )

  // Build the Orders extension (subscribing to Ordering's EP)
  module OrdersExtensionMaker = ReventlessCore.Extension_Builder.Make(
    OrdersExtensionPointSpec,
    OrdersExtension.Mappings,
  )

  // extensionPoints = [module(ProductsExtensionPointMaker)]
  // extensions     = [module(OrdersExtensionMaker)]

  module DcbSpec = CatalogEventLog
}
