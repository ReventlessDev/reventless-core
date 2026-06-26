@@reventless.behavior

// `exists` becomes true once this product's own `ProductAdded` is in the decision
// read — the `productId` clause returns only this product (categoryId is inferred
// payload, so no sibling products leak in), making a plain existence flag enough.
// `liveCategoryIds` holds categories that exist and are not archived — adding a
// product to a missing or archived category is rejected.
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
  | AddProduct({productId, name, description, price, categoryId}) =>
    if state.exists {
      Error(ProductAlreadyExists)
    } else if !(state.liveCategoryIds->Array.includes(categoryId)) {
      Error(CategoryNotFound)
    } else {
      Ok([ProductAdded({productId, name, description, price, categoryId})])
    }
  }
