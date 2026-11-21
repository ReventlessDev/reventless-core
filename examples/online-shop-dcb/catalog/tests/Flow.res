// AUTO-GENERATED — do not edit. Run `npm run generate` to update.

// A flow's steps, one per part, under the part's own name.

// Decisions
module AddCategory = ReventlessGwt.Flow_GWT.DecisionStep(AddCategory, AddCategory_Decision)
module AddProduct = ReventlessGwt.Flow_GWT.DecisionStep(AddProduct, AddProduct_Decision)
module ArchiveCategory = ReventlessGwt.Flow_GWT.DecisionStep(
  ArchiveCategory,
  ArchiveCategory_Decision,
)
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
module RecordProductDemand = ReventlessGwt.Flow_GWT.DecisionStep(
  RecordProductDemand,
  RecordProductDemand_Decision,
)
module RenameCategory = ReventlessGwt.Flow_GWT.DecisionStep(RenameCategory, RenameCategory_Decision)

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
    ChangeProductDescription.deciding,
    ChangeProductName.deciding,
    ChangeProductPrice.deciding,
    RecordProductDemand.deciding,
    RenameCategory.deciding,
  ],
}
