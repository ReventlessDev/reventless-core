@@reventless.behavior

type state = {exists: bool, availableProductIds: Set.t<string>}

let initialState = {exists: false, availableProductIds: Set.make()}

let evolve = (state, event) =>
  switch event {
  | OrderPlaced => {exists: true, availableProductIds: state.availableProductIds}
  | CatalogProductSynced({productId}) =>
    state.availableProductIds->Set.add(productId)
    state
  }

let decide = (state, command) =>
  switch command {
  | PlaceOrder({orderId, customerId, productId}) =>
    if state.exists {
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
