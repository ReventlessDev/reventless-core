@@reventless.behavior

type state = {exists: bool, currentImageUrl: option<string>}

let initialState = {exists: false, currentImageUrl: None}

let evolve = (state, event) =>
  switch event {
  | ProductAdded({imageUrl: ?imageUrl}) => {exists: true, currentImageUrl: imageUrl}
  | ProductImageChanged({imageUrl}) => {
      ...state,
      currentImageUrl: Some(imageUrl),
    }
  }

let decide = (state, command) =>
  switch command {
  | ChangeProductImage({productId, imageUrl}) =>
    if !state.exists {
      Error(ProductNotFound)
    } else if Some(imageUrl) == state.currentImageUrl {
      Ok([]) // idempotent — image unchanged
    } else {
      Ok([ProductImageChanged({productId, imageUrl})])
    }
  }
