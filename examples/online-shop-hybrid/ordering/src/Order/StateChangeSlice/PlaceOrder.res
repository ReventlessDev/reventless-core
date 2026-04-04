// PlaceOrder StateChangeSlice.
// Handles the PlaceOrder command; rejects duplicate placement and validates
// that all referenced products have been synced to the ordering event log.
//
// The tagged array `productIds: array<string>` triggers automatic multi-clause
// query construction: one OR clause per orderId and per productIds element —
// fetching both Order and CatalogProduct events.

@@reventless.spec
@@reventless.dcbTags

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
      orderId: string,
      customerId: string,
      productIds: array<string>,
    })

@schema
type error =
  | OrderAlreadyPlaced
  | ProductsNotAvailable({missing: array<string>})

@schema
type event =
  | OrderPlaced({
      orderId: string,
      customerId: string,
      productIds: array<string>,
    })

let decide = (state, command) =>
  switch command {
  | PlaceOrder({orderId, customerId, productIds}) =>
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
