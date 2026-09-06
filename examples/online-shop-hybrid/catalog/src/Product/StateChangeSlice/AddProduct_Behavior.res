@@reventless.behavior

// `exists` flags whether this product already exists; `liveCategoryIds` holds
// categories that exist and are not archived — adding a product to a missing or
// archived category is rejected. `categoryNames` is not a decision input: nothing
// here accepts or rejects on what a category is called, it is only copied onto
// the event so a shopper sees a name where the row would otherwise show an id.
type state = {
  exists: bool,
  liveCategoryIds: array<string>,
  categoryNames: array<(string, string)>,
}

let initialState = {exists: false, liveCategoryIds: [], categoryNames: []}

// Last writer wins, which is what a rename is: the pair is replaced rather than
// appended, so the fold does not grow without bound as a category is renamed.
let naming = (pairs, categoryId, name) =>
  pairs->Array.filter(((id, _)) => id !== categoryId)->Array.concat([(categoryId, name)])

let evolve = (state, event: consumedEvent) =>
  switch event {
  | ProductAdded(_) => {...state, exists: true}
  | CategoryAdded({categoryId, name}) => {
      ...state,
      liveCategoryIds: state.liveCategoryIds->Array.includes(categoryId)
        ? state.liveCategoryIds
        : Array.concat(state.liveCategoryIds, [categoryId]),
      categoryNames: state.categoryNames->naming(categoryId, name),
    }
  | CategoryRenamed({categoryId, name}) => {
      ...state,
      categoryNames: state.categoryNames->naming(categoryId, name),
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
      let categoryName =
        state.categoryNames
        ->Array.find(((id, _)) => id === categoryId)
        ->Option.map(((_, name)) => name)
      Ok([
        ProductAdded({productId, name, description, price, categoryId, categoryName: ?categoryName}),
      ])
    }
  }
