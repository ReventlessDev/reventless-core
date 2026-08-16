@@reventless.behavior

// `currentPrice` is optional rather than a zero, now that a price is money: a
// zero would have to name a currency, and inventing one for a product that does
// not exist yet is a claim the state cannot support. "No price" and "zero euros"
// are different facts, and only the second one is comparable to a command's.
// Mirrors the read model's lifecycle rather than a pair of booleans, for the
// reason `ArchiveProduct_Behavior` gives: two flags could spell "archived and
// discontinued at once", which is a state the domain does not have.
type shelf = Listed | Archived | Discontinued

type state = {exists: bool, shelf: shelf, currentPrice: option<Reventless.Money.t>}

let initialState = {exists: false, shelf: Listed, currentPrice: None}

let evolve = (state, event) =>
  switch event {
  | ProductAdded({price}) => {exists: true, shelf: Listed, currentPrice: Some(price)}
  | ProductPriceChanged({price}) => {...state, currentPrice: Some(price)}
  | ProductArchived => {...state, shelf: Archived}
  | ProductUnarchived => {...state, shelf: Listed}
  | ProductDiscontinued => {...state, shelf: Discontinued}
  }

let decide = (state, command) =>
  switch command {
  | ChangeProductPrice({productId, price}) =>
    if !state.exists {
      Error(ProductNotFound)
    } else if state.shelf == Discontinued {
      Error(ProductIsDiscontinued)
    } else if state.currentPrice == Some(price) {
      Ok([]) // idempotent — price unchanged
    } else {
      Ok([ProductPriceChanged({productId, price})])
    }
  }
