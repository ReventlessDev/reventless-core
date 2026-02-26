// UpdateProductPrice StateChangeSlice.
// Requires product to exist; idempotent when price is unchanged.

open Reventless
open CatalogEventLog

let name = "UpdateProductPrice"

module DcbEventLogSpec = CatalogEventLog

@schema
type command =
  | UpdateProductPrice({productId: @s.matches(DcbTag.string) string, price: float})

@schema
type error = | ProductNotFound

type decisionModel = {exists: bool, currentPrice: float}

let initialDecisionModel = {exists: false, currentPrice: 0.0}

let reduce = (model, event) =>
  switch event {
  | ProductAdded({price}) => {exists: true, currentPrice: price}
  | ProductPriceUpdated({price}) => {...model, currentPrice: price}
  | _ => model
  }

let decide = (model, command) =>
  switch command {
  | UpdateProductPrice({productId, price}) =>
    if !model.exists {
      Error(ProductNotFound)
    } else if price == model.currentPrice {
      Ok([]) // idempotent — price unchanged
    } else {
      Ok([ProductPriceUpdated({productId, price})])
    }
  }
