@@reventless.behavior

type shelf = Listed | Archived | Discontinued

type state = {exists: bool, shelf: shelf, currentImageUrl: option<string>}

let initialState = {exists: false, shelf: Listed, currentImageUrl: None}

let evolve = (state, event) =>
  switch event {
  | ProductAdded({productImage: ?productImage}) => {exists: true, shelf: Listed, currentImageUrl: productImage}
  | ProductImageChanged({productImage}) => {
      ...state,
      currentImageUrl: Some(productImage),
    }
  | ProductArchived => {...state, shelf: Archived}
  | ProductUnarchived => {...state, shelf: Listed}
  | ProductDiscontinued => {...state, shelf: Discontinued}
  }

let decide = (state, command) =>
  switch command {
  | ChangeProductImage({productId, productImage}) =>
    if !state.exists {
      Error(ProductNotFound)
    } else if state.shelf == Discontinued {
      Error(ProductIsDiscontinued)
    } else if Some(productImage) == state.currentImageUrl {
      Ok([]) // idempotent — image unchanged
    } else {
      Ok([ProductImageChanged({productId, productImage})])
    }
  }
