// Test fixture spec for Phase 2 pluginStructure validation.
// AvailableProductsView SVS: consumes catalog product events.

@@reventless.spec("AvailableProducts")

@schema
type consumedEvent =
  | CatalogProductSynced({productId: string})
  | CatalogProductPriceChanged({productId: string})

@schema
type state = {productId: string}

let project = event =>
  switch event {
  | CatalogProductSynced({productId}) => [Set(productId, {productId: productId})]
  | CatalogProductPriceChanged({productId}) => [Update(productId, s => s)]
  }
