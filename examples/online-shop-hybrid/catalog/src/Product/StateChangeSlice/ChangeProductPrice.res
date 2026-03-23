// ChangeProductPrice StateChangeSlice.
// Requires product to exist; idempotent when price is unchanged.

open Reventless
open CatalogEventLog

let name = "ChangeProductPrice"
let moduleUrl: string = %raw(`import.meta.url`)

module DcbEventLogSpec = CatalogEventLog

@schema
type command = ChangeProductPrice({productId: @s.matches(DcbTag.string) string, price: float})

@schema
type error = ProductNotFound

type state = {exists: bool, currentPrice: float}

let initialState = {exists: false, currentPrice: 0.0}

let evolve = (state, event) =>
  switch event {
  | ProductAdded({price}) => {exists: true, currentPrice: price}
  | ProductPriceChanged({price}) => {...state, currentPrice: price}
  | _ => state
  }

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
