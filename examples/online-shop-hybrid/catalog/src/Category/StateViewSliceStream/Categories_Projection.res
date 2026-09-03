@@reventless.projection

// No `withPrimary` here, unlike the products' projection: a category holds one
// image, so there is no set to fold over and no primary to resolve out of it.
// Three assignments, and the two that name a reference guard on it — a removal
// is the first half of a replacement, and an arm that cleared unconditionally
// would blank the field the second half had just filled.
let project = ({event}) =>
  switch event {
  | CategoryAdded({categoryId, name}) => [Set(categoryId, {categoryId, name, shelfStatus: Listed})]
  | CategoryRenamed({categoryId, name}) => [Update(categoryId, state => {...state, name})]
  | CategoryImageAttached({categoryId, categoryImage, altText: ?altText}) => [
      Update(categoryId, state => {...state, categoryImage, categoryImageAltText: ?altText}),
    ]
  | CategoryImageRemoved({categoryId, categoryImage}) => [
      Update(categoryId, state =>
        state.categoryImage == Some(categoryImage)
          ? {...state, categoryImage: ?None, categoryImageAltText: ?None}
          : state
      ),
    ]
  | CategoryImageAltTextSet({categoryId, categoryImage, altText}) => [
      Update(categoryId, state =>
        state.categoryImage == Some(categoryImage) ? {...state, categoryImageAltText: altText} : state
      ),
    ]
  | CategoryArchived({categoryId}) => [
      Update(categoryId, state => {...state, shelfStatus: Archived}),
    ]
  | CategoryUnarchived({categoryId}) => [
      Update(categoryId, state => {...state, shelfStatus: Listed}),
    ]
  }
