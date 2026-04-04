// ChangeProductPrice StateChangeSlice.
// Requires product to exist; idempotent when price is unchanged.

open Reventless

let name = "ChangeProductPrice"
module Id = Reventless.Id.String
let moduleUrl: string = %raw(`import.meta.url`)

type state = {exists: bool, currentPrice: float}

let initialState = {exists: false, currentPrice: 0.0}

@schema
type consumedEvent =
  | ProductAdded({price: float})
  | ProductPriceChanged({price: float})

let evolve = (state, event) =>
  switch event {
  | ProductAdded({price}) => {exists: true, currentPrice: price}
  | ProductPriceChanged({price}) => {...state, currentPrice: price}
  }

@schema
type command = ChangeProductPrice({productId: @s.matches(DcbTag.string) string, price: float})

@schema
type error = ProductNotFound

@schema
type event =
  | ProductPriceChanged({productId: @s.matches(DcbTag.string) string, price: float})

let decide = (state, command) =>
  switch command {
  | ChangeProductPrice({productId, price}) =>
    if !state.exists {
      Error(ProductNotFound)
    } else if price == state.currentPrice {
      Ok([]) // idempotent — price unchanged
    } else {
      Ok([ProductPriceChanged({productId, price})])
    }
  }
