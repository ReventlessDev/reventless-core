@@reventless.behavior

// The set in attachment order. `primary` is only the one chosen explicitly: until
// then the first attached is primary, and the projection applies the same rule.
type state = {
  exists: bool,
  archived: bool,
  attached: array<string>,
  primary: option<string>,
  altTexts: array<(string, string)>,
}

let initialState = {exists: false, archived: false, attached: [], primary: None, altTexts: []}

let evolve = (state, event) =>
  switch event {
  | CategoryAdded => {...state, exists: true, archived: false}
  | CategoryImageAttached({categoryImage}) =>
    state.attached->Array.includes(categoryImage)
      ? state
      : {...state, attached: state.attached->Array.concat([categoryImage])}
  | CategoryImageRemoved({categoryImage}) => {
      ...state,
      attached: state.attached->Array.filter(r => r != categoryImage),
      primary: state.primary == Some(categoryImage) ? None : state.primary,
      altTexts: state.altTexts->Array.filter(((r, _)) => r != categoryImage),
    }
  | CategoryPrimaryImageSet({categoryImage}) => {...state, primary: Some(categoryImage)}
  | CategoryImageAltTextSet({categoryImage, altText}) => {
      ...state,
      altTexts: state.altTexts
      ->Array.filter(((r, _)) => r != categoryImage)
      ->Array.concat([(categoryImage, altText)]),
    }
  | CategoryArchived => {...state, archived: true}
  | CategoryUnarchived => {...state, archived: false}
  }

let effectivePrimary = state =>
  switch state.primary {
  | Some(_) as p => p
  | None => state.attached->Array.get(0)
  }

let altTextOf = (state, ref) =>
  state.altTexts->Array.find(((r, _)) => r == ref)->Option.map(((_, t)) => t)

let decide = (state, command) =>
  if !state.exists {
    Error(CategoryNotFound)
  } else if state.archived {
    Error(CategoryAlreadyArchived)
  } else {
    switch command {
    | AttachCategoryImage({categoryId, categoryImage, altText: ?altText}) =>
      state.attached->Array.includes(categoryImage)
        ? Ok([])
        : Ok([CategoryImageAttached({categoryId, categoryImage, altText: ?altText})])
    | RemoveCategoryImage({categoryId, categoryImage}) =>
      state.attached->Array.includes(categoryImage)
        ? Ok([CategoryImageRemoved({categoryId, categoryImage})])
        : Ok([])
    | SetPrimaryCategoryImage({categoryId, categoryImage}) =>
      if !(state.attached->Array.includes(categoryImage)) {
        Error(CategoryImageNotAttached)
      } else if effectivePrimary(state) == Some(categoryImage) {
        Ok([])
      } else {
        Ok([CategoryPrimaryImageSet({categoryId, categoryImage})])
      }
    | SetCategoryImageAltText({categoryId, categoryImage, altText}) =>
      if !(state.attached->Array.includes(categoryImage)) {
        Error(CategoryImageNotAttached)
      } else if altTextOf(state, categoryImage) == Some(altText) {
        Ok([])
      } else {
        Ok([CategoryImageAltTextSet({categoryId, categoryImage, altText})])
      }
    }
  }
