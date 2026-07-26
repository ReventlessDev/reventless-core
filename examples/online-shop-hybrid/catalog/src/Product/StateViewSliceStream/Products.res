// Products StateViewSliceStream.
// Projects product events from the shared catalog event log into a Products read model.

@@reventless.spec

@schema
type consumedEvent =
  | ProductAdded({productId: string, name: string, description: string, price: float, imageUrl: string, categoryId: string})
  | ProductNameChanged({productId: string, name: string})
  | ProductDescriptionChanged({productId: string, description: string})
  | ProductPriceChanged({productId: string, price: float})
  | ProductImageChanged({productId: string, imageUrl: string})

@schema
type state = {
  productId: string,
  name: string,
  description: string,
  price: float,
  imageUrl: string,
  categoryId: string,
}
