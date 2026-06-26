@@reventless.behavior

// `addedProductIds` tracks every ProductAdded the multi-clause query returned
// (the `categoryId` tag clause also fetches sibling products in the same
// category), so `decide` can ask "is THIS productId already added?" without
// being confused by siblings. `liveCategoryIds` holds categories that exist and
// are not archived — adding a product to a missing or archived category is
// rejected.
type state = {addedProductIds: array<string>, liveCategoryIds: array<string>}

let initialState = {addedProductIds: [], liveCategoryIds: []}

let evolve = (state, event: consumedEvent) =>
  switch event {
  | ProductAdded({productId}) => {
      ...state,
      addedProductIds: state.addedProductIds->Array.includes(productId)
        ? state.addedProductIds
        : Array.concat(state.addedProductIds, [productId]),
    }
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
    if state.addedProductIds->Array.includes(productId) {
      Error(ProductAlreadyExists)
    } else if !(state.liveCategoryIds->Array.includes(categoryId)) {
      Error(CategoryNotFound)
    } else {
      Ok([ProductAdded({productId, name, description, price, categoryId})])
    }
  }
