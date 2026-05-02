@@reventless.behavior

// `placedOrderIds` tracks every OrderPlaced the query returned (regardless of
// orderId — the multi-clause query also fetches by productId tags), so the
// `decide` step can ask "is THIS particular orderId already placed?" without
// being confused by OrderPlaced events from sibling orders sharing a product.
type state = {placedOrderIds: Set.t<string>, availableProductIds: Set.t<string>}

let initialState = {placedOrderIds: Set.make(), availableProductIds: Set.make()}

let evolve = (state, event: consumedEvent) =>
  switch event {
  | OrderPlaced({orderId}) =>
    state.placedOrderIds->Set.add(orderId)
    state
  | CatalogProductSynced({productId}) =>
    state.availableProductIds->Set.add(productId)
    state
  }

let decide = (state, command) =>
  switch command {
  | PlaceOrder({orderId, customerId, productId}) =>
    if state.placedOrderIds->Set.has(orderId) {
      Error(OrderAlreadyPlaced)
    } else {
      let missing = productId->Array.filter(pid => !(state.availableProductIds->Set.has(pid)))
      if missing->Array.length > 0 {
        Error(ProductsNotAvailable({missing: missing}))
      } else {
        Ok([OrderPlaced({orderId, customerId, productId})])
      }
    }
  }
