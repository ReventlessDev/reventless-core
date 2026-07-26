@@reventless.behavior

type state = {exists: bool, currentImageUrl: string}

let initialState = {exists: false, currentImageUrl: ""}

let evolve = (state, event) =>
  switch event {
  | ProductAdded({imageUrl}) => {exists: true, currentImageUrl: imageUrl}
  | ProductImageChanged({imageUrl}) => {
      ...state,
      currentImageUrl: imageUrl,
    }
  }

let decide = (state, command) =>
  switch command {
  | ChangeProductImage({productId, imageUrl}) =>
    if !state.exists {
      Error(ProductNotFound)
    } else if imageUrl == state.currentImageUrl {
      Ok([]) // idempotent — image unchanged
    } else {
      Ok([ProductImageChanged({productId, imageUrl})])
    }
  }
