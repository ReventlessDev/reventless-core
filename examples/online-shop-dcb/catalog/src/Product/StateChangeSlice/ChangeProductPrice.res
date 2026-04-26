// ChangeProductPrice StateChangeSlice.
// Requires product to exist; idempotent when price is unchanged.
@@reventless.spec

@schema
type consumedEvent =
  | ProductAdded({price: float})
  | ProductPriceChanged({price: float})

@schema
type command = ChangeProductPrice({productId: string, price: float})

@schema
type error = ProductNotFound

@schema
type event = ProductPriceChanged({productId: string, price: float})
