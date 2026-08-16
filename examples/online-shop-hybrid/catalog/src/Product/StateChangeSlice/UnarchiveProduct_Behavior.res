@@reventless.behavior

type shelf = Listed | Archived | Discontinued

type state = {exists: bool, shelf: shelf}

let initialState = {exists: false, shelf: Listed}

let evolve = (state, event) =>
  switch event {
  | ProductAdded => {exists: true, shelf: Listed}
  | ProductArchived => {...state, shelf: Archived}
  | ProductUnarchived => {...state, shelf: Listed}
  | ProductDiscontinued => {...state, shelf: Discontinued}
  }

let decide = (state, command) =>
  switch command {
  | UnarchiveProduct({productId: theId}) =>
    if !state.exists {
      Error(ProductNotFound)
    } else {
      switch state.shelf {
      // The assertion that makes `Discontinued` terminal in the aggregate and not
      // only in the diagram. `@allowedStates` already keeps this off the menu for
      // a discontinued product; refusing here is what holds when a caller posts
      // the command anyway.
      | Discontinued => Error(ProductIsDiscontinued)
      | Listed => Ok([]) // idempotent — already in the catalog
      | Archived => Ok([ProductUnarchived({productId: theId})])
      }
    }
  }
