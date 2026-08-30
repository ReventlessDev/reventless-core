@@reventless.projection

// The primary falls back to the first attached, so a set never shows no image
// while it has one.
let withPrimary = (state: Categories.state, chosen: option<string>) =>
  switch chosen {
  | Some(_) as p => {...state, categoryImage: ?p}
  | None =>
    switch state.categoryImages->Array.get(0) {
    | Some(first) => {...state, categoryImage: first.categoryImage}
    | None => {...state, categoryImage: ?None}
    }
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
