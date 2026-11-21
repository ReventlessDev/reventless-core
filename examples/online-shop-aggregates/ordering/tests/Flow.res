// AUTO-GENERATED — do not edit. Run `npm run generate` to update.

// A flow's steps, one per part, under the part's own name.

// Aggregates
module CatalogProduct = ReventlessGwt.Flow_GWT.AggregateStep(
  CatalogProduct,
  CatalogProduct_Decision,
)
module Customer = ReventlessGwt.Flow_GWT.AggregateStep(Customer, Customer_Decision)
module Order = ReventlessGwt.Flow_GWT.AggregateStep(Order, Order_Decision)

// Extension points
module Orders_ExtensionPoint = ReventlessGwt.Flow_GWT.ExtensionPointStep(
  Orders_ExtensionPointMapping,
)

// Extensions
module Products_Extension = ReventlessGwt.Flow_GWT.ExtensionStep(Products_Extension.Mapping)

// What reacts and what decides, for `thenNothingElseReacts` and `whenSettled`.
let parts: ReventlessGwt.Flow_GWT.parts = {
  reacting: [Products_Extension.reacting],
  deciding: [],
}
