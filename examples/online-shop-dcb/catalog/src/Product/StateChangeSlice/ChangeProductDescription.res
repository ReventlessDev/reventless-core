// ChangeProductDescription StateChangeSlice.
// Requires product to exist; idempotent when description is unchanged.
@@reventless.spec
@@reventless.dcbTags

type state = {exists: bool, currentDescription: string}

let initialState = {exists: false, currentDescription: ""}

@schema
type consumedEvent =
  | ProductAdded({description: string})
  | ProductDescriptionChanged({description: string})

let evolve = (state, event) =>
  switch event {
  | ProductAdded({description}) => {exists: true, currentDescription: description}
  | ProductDescriptionChanged({description}) => {
      ...state,
      currentDescription: description,
    }
  }

@schema
type command =
  | ChangeProductDescription({productId: string, description: string})

@schema
type error = ProductNotFound

@schema
type event =
  | ProductDescriptionChanged({
      productId: string,
      description: string,
    })

let decide = (state, command) =>
  switch command {
  | ChangeProductDescription({productId, description}) =>
    if !state.exists {
      Error(ProductNotFound)
    } else if description == state.currentDescription {
      Ok([]) // idempotent — description unchanged
    } else {
      Ok([ProductDescriptionChanged({productId, description})])
    }
  }
