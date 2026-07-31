// ChangeProductPrice StateChangeSlice.
// Requires product to exist; idempotent when price is unchanged.

@@reventless.spec

@schema
type consumedEvent =
  | ProductAdded({price: Reventless.Money.t})
  | ProductPriceChanged({price: Reventless.Money.t})

@schema
type command = ChangeProductPrice({productId: string, price: Reventless.Money.t})

@schema
type error = ProductNotFound

@schema
type event =
  | ProductPriceChanged({productId: string, price: Reventless.Money.t})
