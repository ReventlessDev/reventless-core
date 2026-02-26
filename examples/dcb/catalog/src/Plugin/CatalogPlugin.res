// Catalog DCB plugin — platform-agnostic composition root.
// Wires the shared event log, all StateChangeSlices, and StateViewSlices for Product and Category.

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

  module DcbSpec = CatalogEventLog
}
