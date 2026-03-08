// PlaceOrder StateChangeSlice.
// Handles the PlaceOrder command; rejects duplicate placement and validates
// that all referenced products have been synced to the ordering event log.
//
// The tagged array `productId: array<@s.matches(DcbTag.string) string>` triggers
// automatic multi-clause query construction: one OR clause per orderId and per
// productId element — fetching both Order and CatalogProduct events.
//
// The command field is named `productId` (singular) to match the tag key on
// CatalogProductSynced events. The JSON wire format uses "productId" as well.

open Reventless
open OrderingEventLog

let name = "PlaceOrder"

module DcbEventLogSpec = OrderingEventLog

@schema
type command =
  | PlaceOrder({
      orderId: @s.matches(DcbTag.string) string,
      customerId: string,
      productId: array<@s.matches(DcbTag.string) string>,
    })

@schema
type error =
  | OrderAlreadyPlaced
  | ProductsNotAvailable({missing: array<string>})

type decisionModel = {exists: bool, availableProductIds: Set.t<string>}

let initialDecisionModel = {exists: false, availableProductIds: Set.make()}

let reduce = (model, event) =>
  switch event {
  | OrderPlaced(_) => {exists: true, availableProductIds: model.availableProductIds}
  | CatalogProductSynced({productId}) =>
    model.availableProductIds->Set.add(productId)
    model
  | _ => model
  }

let decide = (model, command) =>
  switch command {
  | PlaceOrder({orderId, customerId, productId: productIds}) =>
    if model.exists {
      Error(OrderAlreadyPlaced)
    } else {
      let missing = productIds->Array.filter(pid => !(model.availableProductIds->Set.has(pid)))
      if missing->Array.length > 0 {
        Error(ProductsNotAvailable({missing: missing}))
      } else {
        Ok([OrderPlaced({orderId, customerId, productIds})])
      }
    }
  }
