@@reventless.behavior

// `exists` flags whether this product already exists; `liveCategoryIds` holds
// categories that exist and are not archived — adding a product to a missing or
// archived category is rejected.
type state = {exists: bool, liveCategoryIds: array<string>}

let initialState = {exists: false, liveCategoryIds: []}

let evolve = (state, event: consumedEvent) =>
  switch event {
  | ProductAdded(_) => {...state, exists: true}
  | CategoryAdded({categoryId}) => {
      ...state,
      liveCategoryIds: state.liveCategoryIds->Array.includes(categoryId)
        ? state.liveCategoryIds
        : Array.concat(state.liveCategoryIds, [categoryId]),
    }
  | CategoryArchived({categoryId}) => {
      ...state,
      liveCategoryIds: state.liveCategoryIds->Array.filter(id => id !== categoryId),
    }
  }

let decide = (state, command) =>
  switch command {
  | AddProduct({productId, name, description, price, imageUrl: ?imageUrl, categoryId}) =>
    if state.exists {
      Error(ProductAlreadyExists)
    } else if !(state.liveCategoryIds->Array.includes(categoryId)) {
      Error(CategoryNotFound)
    } else {
      Ok([ProductAdded({productId, name, description, price, imageUrl: ?imageUrl, categoryId})])
    }
  }
