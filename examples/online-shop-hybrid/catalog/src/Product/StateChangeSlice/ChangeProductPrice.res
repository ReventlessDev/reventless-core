// ChangeProductPrice StateChangeSlice.
// Requires product to exist; idempotent when price is unchanged.

open Reventless
open CatalogEventLog

let name = "ChangeProductPrice"

module DcbEventLogSpec = CatalogEventLog

@schema
type command =
  | ChangeProductPrice({productId: @s.matches(DcbTag.string) string, price: float})

@schema
type error = | ProductNotFound

type decisionModel = {exists: bool, currentPrice: float}

let initialDecisionModel = {exists: false, currentPrice: 0.0}

let reduce = (model, event) =>
  switch event {
  | ProductAdded({price}) => {exists: true, currentPrice: price}
  | ProductPriceChanged({price}) => {...model, currentPrice: price}
  | _ => model
  }

let decide = (model, command) =>
  switch command {
  | ChangeProductPrice({productId, price}) =>
    if !model.exists {
      Error(ProductNotFound)
    } else if price == model.currentPrice {
      Ok([]) // idempotent — price unchanged
    } else {
      Ok([ProductPriceChanged({productId, price})])
    }
  }
