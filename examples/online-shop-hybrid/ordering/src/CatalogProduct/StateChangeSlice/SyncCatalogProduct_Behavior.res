@@reventless.behavior

// No price until one has been synced — see ChangeProductPrice_Behavior for why
// a money field's "empty" is an absence rather than a zero.
//
// `withdrawn` sits beside the shadow rather than replacing it: a withdrawn
// product's name and price are exactly what a relist needs, and dropping them
// here would force Catalog to re-send facts Ordering already holds.
type state = {name: string, price: option<Reventless.Money.t>, withdrawn: bool}
let initialState = {name: "", price: None, withdrawn: false}

let evolve = (state, event) =>
  switch event {
  | CatalogProductSynced({name, price}) => {name, price: Some(price), withdrawn: false}
  | CatalogProductPriceChanged({price}) => {...state, price: Some(price)}
  | CatalogProductWithdrawn => {...state, withdrawn: true}
  | CatalogProductRelisted => {...state, withdrawn: false}
  }

let decide = (state, command) =>
  switch command {
  | SyncNewProduct({productId, name, price}) =>
    // Idempotent: re-syncing identical data emits nothing (at-least-once delivery).
    if state.name == name && state.price == Some(price) && !state.withdrawn {
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
  | WithdrawSyncedProduct({productId: theId}) =>
    if state.withdrawn {
      Ok([])
    } else {
      Ok([CatalogProductWithdrawn({productId: theId})])
    }
  | RelistSyncedProduct({productId: theId}) =>
    switch (state.withdrawn, state.price) {
    | (false, _) => Ok([]) // idempotent — already orderable
    // A relist of a product never synced has nothing to restore. Emitting an
    // event with an invented name and a zero price would put a row in the
    // shopper's catalog that no Catalog product backs.
    | (true, None) => Ok([])
    | (true, Some(price)) =>
      Ok([CatalogProductRelisted({productId: theId, name: state.name, price})])
    }
  }
