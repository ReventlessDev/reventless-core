// Products StateViewSliceStream.
// Projects product events from the shared catalog event log into a Products read model.

@@reventless.spec

@schema
type consumedEvent =
  | ProductAdded({productId: string, name: string, description: string, price: Reventless.Money.t, imageUrl?: string, categoryId: string})
  | ProductNameChanged({productId: string, name: string})
  | ProductDescriptionChanged({productId: string, description: string})
  | ProductPriceChanged({productId: string, price: Reventless.Money.t})
  | ProductImageChanged({productId: string, imageUrl: string})

@schema
type state = {
  productId: string,
  name: string,
  description: string,
  price: Reventless.Money.t,
  @storageRef("productImages") imageUrl?: string,
  categoryId: string,
}
