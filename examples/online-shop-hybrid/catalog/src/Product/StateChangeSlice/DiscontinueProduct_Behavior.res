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
  | DiscontinueProduct({productId: theId}) =>
    if !state.exists {
      Error(ProductNotFound)
    } else {
      switch state.shelf {
      | Discontinued => Ok([]) // idempotent — already gone for good
      | Listed | Archived => Ok([ProductDiscontinued({productId: theId})])
      }
    }
  }
