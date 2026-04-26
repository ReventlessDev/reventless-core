@@reventless.behavior

type state = {exists: bool, currentName: string}

let initialState = {exists: false, currentName: ""}

let evolve = (state, event) =>
  switch event {
  | ProductAdded({name}) => {exists: true, currentName: name}
  | ProductNameChanged({name}) => {...state, currentName: name}
  }

let decide = (state, command) =>
  switch command {
  | ChangeProductName({productId, name}) =>
    if !state.exists {
      Error(ProductNotFound)
    } else if name == state.currentName {
      Ok([]) // idempotent — name unchanged
    } else {
      Ok([ProductNameChanged({productId, name})])
    }
  }
