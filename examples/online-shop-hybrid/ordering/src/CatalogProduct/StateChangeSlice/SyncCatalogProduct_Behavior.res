@@reventless.behavior

type state = {name: string, price: float}
let initialState = {name: "", price: 0.0}

let evolve = (state, event) =>
  switch event {
  | CatalogProductSynced({name, price}) => {name, price}
  | CatalogProductPriceChanged({price}) => {...state, price}
  }

let decide = (_state, command) =>
  switch command {
  | SyncNewProduct({productId, name, price}) => Ok([CatalogProductSynced({productId, name, price})])
  | ChangeSyncedPrice({productId, price}) => Ok([CatalogProductPriceChanged({productId, price})])
  }
