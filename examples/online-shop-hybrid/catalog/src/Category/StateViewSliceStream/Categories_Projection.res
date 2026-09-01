@@reventless.projection

// The fallback to the first attached is the trait's rule, applied here over the
// view's own rows so a card never shows no image while the set holds one.
let withPrimary = (state: Categories.state, chosen: option<string>) => {
  ...state,
  categoryImage: ?TraitAttachments.Attachments_Rules.primaryOf(
    ~chosen,
    ~attached=state.categoryImages->Array.map(a => a.categoryImage),
  ),
}

let project = ({event}) =>
  switch event {
  | CategoryAdded({categoryId, name}) => [
      Set(categoryId, {categoryId, name, shelfStatus: Listed, categoryImages: []}),
    ]
  | CategoryRenamed({categoryId, name}) => [Update(categoryId, state => {...state, name})]
  | CategoryImageAttached({categoryId, categoryImage, altText: ?altText}) => [
      Update(categoryId, state =>
        state.categoryImages->Array.some(a => a.categoryImage == categoryImage)
          ? state
          : withPrimary(
              {
                ...state,
                categoryImages: state.categoryImages->Array.concat([{categoryImage, altText: ?altText}]),
              },
              state.categoryImage,
            )
      ),
    ]
  | CategoryImageRemoved({categoryId, categoryImage}) => [
      Update(categoryId, state =>
        withPrimary(
          {...state, categoryImages: state.categoryImages->Array.filter(a => a.categoryImage != categoryImage)},
          state.categoryImage == Some(categoryImage) ? None : state.categoryImage,
        )
      ),
    ]
  | CategoryPrimaryImageSet({categoryId, categoryImage}) => [
      Update(categoryId, state => {...state, categoryImage}),
    ]
  | CategoryImageAltTextSet({categoryId, categoryImage, altText}) => [
      Update(categoryId, state => {
        ...state,
        categoryImages: state.categoryImages->Array.map(a =>
          a.categoryImage == categoryImage ? {...a, altText} : a
        ),
      }),
    ]
  | CategoryArchived({categoryId}) => [
      Update(categoryId, state => {...state, shelfStatus: Archived}),
    ]
  | CategoryUnarchived({categoryId}) => [
      Update(categoryId, state => {...state, shelfStatus: Listed}),
    ]
  }
