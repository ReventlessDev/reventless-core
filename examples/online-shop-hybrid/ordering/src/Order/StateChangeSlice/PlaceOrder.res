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

let name = "PlaceOrder"
let moduleUrl: string = %raw(`import.meta.url`)

type state = {exists: bool, availableProductIds: Set.t<string>}

let initialState = {exists: false, availableProductIds: Set.make()}

@schema
type consumedEvent =
  | OrderPlaced
  | CatalogProductSynced({productId: string})

let evolve = (state, event) =>
  switch event {
  | OrderPlaced => {exists: true, availableProductIds: state.availableProductIds}
  | CatalogProductSynced({productId}) =>
    state.availableProductIds->Set.add(productId)
    state
  }

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

@schema
type producedEvent =
  | OrderPlaced({
      orderId: @s.matches(DcbTag.string) string,
      customerId: string,
      productIds: array<string>,
    })

let decide = (state, command) =>
  switch command {
  | PlaceOrder({orderId, customerId, productId: productIds}) =>
    if state.exists {
      Error(OrderAlreadyPlaced)
    } else {
      let missing = productIds->Array.filter(pid => !(state.availableProductIds->Set.has(pid)))
      if missing->Array.length > 0 {
        Error(ProductsNotAvailable({missing: missing}))
      } else {
        Ok([OrderPlaced({orderId, customerId, productIds})])
      }
    }
  }
