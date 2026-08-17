@@reventless.behavior

// Stored as immutable arrays (rather than `Set.t`) so each fold yields a fresh
// state — `evolve` returns a new record instead of mutating a shared one. This
// keeps successive `decide` calls (and unit tests) hermetic.
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
  | CatalogProductSynced({productId})
  | CatalogProductRelisted({productId}) => {
      ...state,
      availableProductIds: state.availableProductIds->Array.includes(productId)
        ? state.availableProductIds
        : Array.concat(state.availableProductIds, [productId]),
    }
  // The half that was missing: without it the set only ever grows, and a
  // withdrawn product stays orderable. Removing the id is what keeps this
  // decision agreeing with the `AvailableProducts` view, which deletes the row.
  | CatalogProductWithdrawn({productId}) => {
      ...state,
      availableProductIds: state.availableProductIds->Array.filter(id => id != productId),
    }
  }

let decide = (state, command) =>
  switch command {
  | PlaceOrder({orderId, customerId, productIds, shippingMethod, deliveryWindow: ?deliveryWindow}) =>
    if state.placedOrderIds->Array.includes(orderId) {
      Error(OrderAlreadyPlaced)
    } else {
      let missing = productIds->Array.filter(pid => !(state.availableProductIds->Array.includes(pid)))
      if missing->Array.length > 0 {
        Error(ProductsNotAvailable({missing: missing}))
      } else {
        Ok([OrderPlaced({orderId, customerId, productIds, shippingMethod, deliveryWindow: ?deliveryWindow})])
      }
    }
  }
