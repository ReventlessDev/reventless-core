// Products StateViewSlice.
// Projects product events from the shared catalog event log into a Products read model.
@@reventless.spec

// Rows are keyed by this identity.
module Key = CatalogSpec.ProductId

@schema
type state = {productId: CatalogSpec.ProductId.t, name: string, description: string, price: float}

@schema
type consumedEvent =
  | ProductAdded({
      productId: CatalogSpec.ProductId.t,
      name: string,
      description: string,
      price: float,
    })
  | ProductNameChanged({productId: CatalogSpec.ProductId.t, name: string})
  | ProductDescriptionChanged({productId: CatalogSpec.ProductId.t, description: string})
  | ProductPriceChanged({productId: CatalogSpec.ProductId.t, price: float})
