@@reventless.behavior

type state = {name: string, price: float}
let initialState = {name: "", price: 0.0}

let evolve = (state, event) =>
  switch event {
  | CatalogProductSynced({name, price}) => {name, price}
  | CatalogProductPriceChanged({price}) => {...state, price}
  }

let decide = (state, command) =>
  switch command {
  | SyncNewProduct({productId, name, price}) =>
    // Idempotent: re-syncing identical data emits nothing (at-least-once delivery).
    if state.name == name && state.price == price {
      Ok([])
    } else {
      Ok([CatalogProductSynced({productId, name, price})])
    }
  | ChangeSyncedPrice({productId, price}) =>
    if state.price == price {
      Ok([])
    } else {
      Ok([CatalogProductPriceChanged({productId, price})])
    }
  }
