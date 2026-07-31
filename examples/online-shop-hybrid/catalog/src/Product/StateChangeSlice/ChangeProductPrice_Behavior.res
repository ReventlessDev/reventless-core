@@reventless.behavior

// `currentPrice` is optional rather than a zero, now that a price is money: a
// zero would have to name a currency, and inventing one for a product that does
// not exist yet is a claim the state cannot support. "No price" and "zero euros"
// are different facts, and only the second one is comparable to a command's.
type state = {exists: bool, currentPrice: option<Reventless.Money.t>}

let initialState = {exists: false, currentPrice: None}

let evolve = (state, event) =>
  switch event {
  | ProductAdded({price}) => {exists: true, currentPrice: Some(price)}
  | ProductPriceChanged({price}) => {...state, currentPrice: Some(price)}
  }

let decide = (state, command) =>
  switch command {
  | ChangeProductPrice({productId, price}) =>
    if !state.exists {
      Error(ProductNotFound)
    } else if state.currentPrice == Some(price) {
      Ok([]) // idempotent — price unchanged
    } else {
      Ok([ProductPriceChanged({productId, price})])
    }
  }
