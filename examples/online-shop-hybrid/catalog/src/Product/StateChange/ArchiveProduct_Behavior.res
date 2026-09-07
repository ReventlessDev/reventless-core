@@reventless.behavior

// The aggregate's own reading of where the product is. `shelf` mirrors the read
// model's lifecycle rather than a pair of booleans: two flags could spell
// "archived and discontinued at once", which is a state the domain does not have.
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
  | ArchiveProduct({productId: theId}) =>
    if !state.exists {
      Error(ProductNotFound)
    } else {
      switch state.shelf {
      | Discontinued => Error(ProductIsDiscontinued)
      | Archived => Ok([]) // idempotent — already off the shelf
      | Listed => Ok([ProductArchived({productId: theId})])
      }
    }
  }
