@@reventless.behavior

type state = {exists: bool, currentPrice: float}

let initialState = {exists: false, currentPrice: 0.0}

let evolve = (state, event) =>
  switch event {
  | ProductAdded({price}) => {exists: true, currentPrice: price}
  | ProductPriceChanged({price}) => {...state, currentPrice: price}
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
