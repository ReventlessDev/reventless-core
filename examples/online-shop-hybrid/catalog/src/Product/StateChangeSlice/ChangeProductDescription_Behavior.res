@@reventless.behavior

type state = {exists: bool, currentDescription: string}

let initialState = {exists: false, currentDescription: ""}

let evolve = (state, event) =>
  switch event {
  | ProductAdded({description}) => {exists: true, currentDescription: description}
  | ProductDescriptionChanged({description}) => {
      ...state,
      currentDescription: description,
    }
  }

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
