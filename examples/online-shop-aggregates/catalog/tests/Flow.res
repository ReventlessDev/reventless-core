// AUTO-GENERATED — do not edit. Run `npm run generate` to update.

// A flow's steps, one per part, under the part's own name.

// Aggregates
module Category = ReventlessGwt.Flow_GWT.AggregateStep(Category, Category_Decision)
module Product = ReventlessGwt.Flow_GWT.AggregateStep(Product, Product_Decision)
module ProductDemand = ReventlessGwt.Flow_GWT.AggregateStep(ProductDemand, ProductDemand_Decision)

// Extension points
module Products_ExtensionPoint = ReventlessGwt.Flow_GWT.ExtensionPointStep(
  Products_ExtensionPointMapping,
)

// Extensions
module Orders_Extension = ReventlessGwt.Flow_GWT.ExtensionStep(Orders_Extension.Mapping)
