// AddProduct StateChangeSlice.
// Handles the AddProduct command; rejects duplicate creation via DCB optimistic concurrency.
@@reventless.spec
@@reventless.dcbTags

type state = {exists: bool}

let initialState = {exists: false}

@schema
type consumedEvent =
  | ProductAdded

let evolve = (_state, event) =>
  switch event {
  | ProductAdded => {exists: true}
  }

@schema
type command =
  | AddProduct({
      productId: string,
      name: string,
      description: string,
      price: float,
    })

@schema
type error = ProductAlreadyExists

@schema
type event =
  | ProductAdded({
      productId: string,
      name: string,
      description: string,
      price: float,
    })

let decide = (state, command) =>
  switch command {
  | AddProduct({productId, name, description, price}) =>
    if state.exists {
      Error(ProductAlreadyExists)
    } else {
      Ok([ProductAdded({productId, name, description, price})])
    }
  }
