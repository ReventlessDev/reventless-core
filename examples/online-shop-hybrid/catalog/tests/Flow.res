// AUTO-GENERATED — do not edit. Run `npm run generate` to update.

// A flow's steps, one per part, under the part's own name.

// Decisions
module AddCategory = ReventlessGwt.Flow_GWT.DecisionStep(AddCategory, AddCategory_Decision)
module AddProduct = ReventlessGwt.Flow_GWT.DecisionStep(AddProduct, AddProduct_Decision)
module ArchiveCategory = ReventlessGwt.Flow_GWT.DecisionStep(
  ArchiveCategory,
  ArchiveCategory_Decision,
)
module ArchiveProduct = ReventlessGwt.Flow_GWT.DecisionStep(ArchiveProduct, ArchiveProduct_Decision)
module CategoryImages = ReventlessGwt.Flow_GWT.DecisionStep(CategoryImages, CategoryImages_Decision)
module ChangeProductDescription = ReventlessGwt.Flow_GWT.DecisionStep(
  ChangeProductDescription,
  ChangeProductDescription_Decision,
)
module ChangeProductName = ReventlessGwt.Flow_GWT.DecisionStep(
  ChangeProductName,
  ChangeProductName_Decision,
)
module ChangeProductPrice = ReventlessGwt.Flow_GWT.DecisionStep(
  ChangeProductPrice,
  ChangeProductPrice_Decision,
)
module DiscontinueProduct = ReventlessGwt.Flow_GWT.DecisionStep(
  DiscontinueProduct,
  DiscontinueProduct_Decision,
)
module ProductImages = ReventlessGwt.Flow_GWT.DecisionStep(ProductImages, ProductImages_Decision)
module RecordProductDemand = ReventlessGwt.Flow_GWT.DecisionStep(
  RecordProductDemand,
  RecordProductDemand_Decision,
)
module RenameCategory = ReventlessGwt.Flow_GWT.DecisionStep(RenameCategory, RenameCategory_Decision)
module UnarchiveCategory = ReventlessGwt.Flow_GWT.DecisionStep(
  UnarchiveCategory,
  UnarchiveCategory_Decision,
)
module UnarchiveProduct = ReventlessGwt.Flow_GWT.DecisionStep(
  UnarchiveProduct,
  UnarchiveProduct_Decision,
)

// Views
module Categories = ReventlessGwt.Flow_GWT.ViewStep(Categories, Categories_Projection)
module ProductDemand = ReventlessGwt.Flow_GWT.ViewStep(ProductDemand, ProductDemand_Projection)
module Products = ReventlessGwt.Flow_GWT.ViewStep(Products, Products_Projection)

// Ways in
module ImportProduct = ReventlessGwt.Flow_GWT.InboundStep(ImportProduct, ImportProduct_Translation)

// Extension points
module Products_ExtensionPoint = ReventlessGwt.Flow_GWT.ExtensionPointStep(
  Products_ExtensionPointMapping,
)

// Extensions
module Orders_Extension = ReventlessGwt.Flow_GWT.ExtensionStep(Orders_Extension.Mapping)

// What reacts and what decides, for `thenNothingElseReacts` and `whenSettled`.
let parts: ReventlessGwt.Flow_GWT.parts = {
  reacting: [Orders_Extension.reacting],
  deciding: [
    AddCategory.deciding,
    AddProduct.deciding,
    ArchiveCategory.deciding,
    ArchiveProduct.deciding,
    CategoryImages.deciding,
    ChangeProductDescription.deciding,
    ChangeProductName.deciding,
    ChangeProductPrice.deciding,
    DiscontinueProduct.deciding,
    ProductImages.deciding,
    RecordProductDemand.deciding,
    RenameCategory.deciding,
    UnarchiveCategory.deciding,
    UnarchiveProduct.deciding,
  ],
}
