// AvailableProductsView StateViewSlice.
// Projects synced catalog product events into a queryable "available products" read model.
@@reventless.spec


open Reventless.Projection


@schema
type state = {productId: string, name: string, price: float}

@schema
type consumedEvent =
  | CatalogProductSynced({productId: string, name: string, price: float})
  | CatalogProductPriceChanged({productId: string, price: float})

let project = event =>
  switch event {
  | CatalogProductSynced({productId, name, price}) => [Set(productId, {productId, name, price})]
  | CatalogProductPriceChanged({productId, price}) =>
    [Update(productId, p => {...p, price})]
  }
