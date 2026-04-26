// ProductsView StateViewSlice.
// Projects product events from the shared catalog event log into a Products read model.

@@reventless.spec

@schema
type consumedEvent =
  | ProductAdded({productId: string, name: string, description: string, price: float})
  | ProductNameChanged({productId: string, name: string})
  | ProductDescriptionChanged({productId: string, description: string})
  | ProductPriceChanged({productId: string, price: float})

@schema
type state = {productId: string, name: string, description: string, price: float}
