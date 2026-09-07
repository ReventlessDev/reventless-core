@@reventless.behavior

type shelf = Listed | Archived | Discontinued

type state = {exists: bool, shelf: shelf, currentName: string}

let initialState = {exists: false, shelf: Listed, currentName: ""}

let evolve = (state, event) =>
  switch event {
  | ProductAdded({name}) => {exists: true, shelf: Listed, currentName: name}
  | ProductNameChanged({name}) => {...state, currentName: name}
  | ProductArchived => {...state, shelf: Archived}
  | ProductUnarchived => {...state, shelf: Listed}
  | ProductDiscontinued => {...state, shelf: Discontinued}
  }

let decide = (state, command) =>
  switch command {
  | ChangeProductName({productId, name}) =>
    if !state.exists {
      Error(ProductNotFound)
    } else if state.shelf == Discontinued {
      Error(ProductIsDiscontinued)
    } else if name == state.currentName {
      Ok([]) // idempotent — name unchanged
    } else {
      Ok([ProductNameChanged({productId, name})])
    }
  }
