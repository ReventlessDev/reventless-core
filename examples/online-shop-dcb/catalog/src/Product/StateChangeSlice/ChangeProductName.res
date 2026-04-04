// ChangeProductName StateChangeSlice.
// Requires product to exist; idempotent when name is unchanged.
@@reventless.spec

type state = {exists: bool, currentName: string}

let initialState = {exists: false, currentName: ""}

@schema
type consumedEvent =
  | ProductAdded({name: string})
  | ProductNameChanged({name: string})

let evolve = (state, event) =>
  switch event {
  | ProductAdded({name}) => {exists: true, currentName: name}
  | ProductNameChanged({name}) => {...state, currentName: name}
  }

@schema
type command = ChangeProductName({productId: string, name: string})

@schema
type error = ProductNotFound

@schema
type event = ProductNameChanged({productId: string, name: string})

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
