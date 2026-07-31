@@reventless.behavior

// No price until one has been synced — see ChangeProductPrice_Behavior for why
// a money field's "empty" is an absence rather than a zero.
type state = {name: string, price: option<Reventless.Money.t>}
let initialState = {name: "", price: None}

let evolve = (state, event) =>
  switch event {
  | CatalogProductSynced({name, price}) => {name, price: Some(price)}
  | CatalogProductPriceChanged({price}) => {...state, price: Some(price)}
  }

let decide = (state, command) =>
  switch command {
  | SyncNewProduct({productId, name, price}) =>
    // Idempotent: re-syncing identical data emits nothing (at-least-once delivery).
    if state.name == name && state.price == Some(price) {
      Ok([])
    } else {
      Ok([CatalogProductSynced({productId, name, price})])
    }
  | ChangeSyncedPrice({productId, price}) =>
    if state.price == Some(price) {
      Ok([])
    } else {
      Ok([CatalogProductPriceChanged({productId, price})])
    }
  }
