@@reventless.behavior

type shelf = Listed | Archived | Discontinued

type state = {exists: bool, shelf: shelf, currentDescription: string}

let initialState = {exists: false, shelf: Listed, currentDescription: ""}

let evolve = (state, event) =>
  switch event {
  | ProductAdded({description}) => {exists: true, shelf: Listed, currentDescription: description}
  | ProductDescriptionChanged({description}) => {
      ...state,
      currentDescription: description,
    }
  | ProductArchived => {...state, shelf: Archived}
  | ProductUnarchived => {...state, shelf: Listed}
  | ProductDiscontinued => {...state, shelf: Discontinued}
  }

let decide = (state, command) =>
  switch command {
  | ChangeProductDescription({productId, description}) =>
    if !state.exists {
      Error(ProductNotFound)
    } else if state.shelf == Discontinued {
      Error(ProductIsDiscontinued)
    } else if description == state.currentDescription {
      Ok([]) // idempotent — description unchanged
    } else {
      Ok([ProductDescriptionChanged({productId, description})])
    }
  }
