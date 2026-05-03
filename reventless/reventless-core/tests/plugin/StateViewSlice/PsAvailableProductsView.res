// Test fixture spec for Phase 2 pluginStructure validation.
// AvailableProductsView SVS: consumes catalog product events.

@@reventless.spec("AvailableProducts")

@schema
type consumedEvent =
  | CatalogProductSynced({productId: string, name: string})
  | CatalogProductPriceChanged({productId: string})

@schema
type state = {productId: string, name: string}

let project = event =>
  switch event {
  | CatalogProductSynced({productId, name}) => [Set(productId, {productId, name})]
  | CatalogProductPriceChanged({productId}) => [Update(productId, s => s)]
  }
