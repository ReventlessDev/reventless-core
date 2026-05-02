@@reventless.behavior

// `placedOrderIds` tracks every OrderPlaced the query returned (regardless of
// orderId — the multi-clause query also fetches by productId tags), so the
// `decide` step can ask "is THIS particular orderId already placed?" without
// being confused by OrderPlaced events from sibling orders sharing a product.
//
// Stored as immutable arrays (rather than `Set.t`) so each fold yields a
// fresh state — `evolve` returns a new record instead of mutating a shared
// one. This keeps successive `decide` calls (and unit tests) hermetic.
type state = {placedOrderIds: array<string>, availableProductIds: array<string>}

let initialState = {placedOrderIds: [], availableProductIds: []}

let evolve = (state, event: consumedEvent) =>
  switch event {
  | OrderPlaced({orderId}) => {
      ...state,
      placedOrderIds: state.placedOrderIds->Array.includes(orderId)
        ? state.placedOrderIds
        : Array.concat(state.placedOrderIds, [orderId]),
    }
  | CatalogProductSynced({productId}) => {
      ...state,
      availableProductIds: state.availableProductIds->Array.includes(productId)
        ? state.availableProductIds
        : Array.concat(state.availableProductIds, [productId]),
    }
  }

let decide = (state, command) =>
  switch command {
  | PlaceOrder({orderId, customerId, productId}) =>
    if state.placedOrderIds->Array.includes(orderId) {
      Error(OrderAlreadyPlaced)
    } else {
      let missing = productId->Array.filter(pid => !(state.availableProductIds->Array.includes(pid)))
      if missing->Array.length > 0 {
        Error(ProductsNotAvailable({missing: missing}))
      } else {
        Ok([OrderPlaced({orderId, customerId, productId})])
      }
    }
  }
