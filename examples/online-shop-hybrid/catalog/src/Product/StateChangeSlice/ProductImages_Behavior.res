@@reventless.behavior

type shelf = Listed | Archived | Discontinued

// The set in attachment order. `primary` is only the one chosen explicitly: until
// then the first attached is primary, and the projection applies the same rule.
type state = {
  exists: bool,
  shelf: shelf,
  attached: array<string>,
  primary: option<string>,
  altTexts: array<(string, string)>,
}

let initialState = {exists: false, shelf: Listed, attached: [], primary: None, altTexts: []}

let evolve = (state, event) =>
  switch event {
  | ProductAdded(_) => {...state, exists: true}
  | ProductImageAttached({productImage}) =>
    state.attached->Array.includes(productImage)
      ? state
      : {...state, attached: state.attached->Array.concat([productImage])}
  | ProductImageRemoved({productImage}) => {
      ...state,
      attached: state.attached->Array.filter(r => r != productImage),
      primary: state.primary == Some(productImage) ? None : state.primary,
      altTexts: state.altTexts->Array.filter(((r, _)) => r != productImage),
    }
  | ProductPrimaryImageSet({productImage}) => {...state, primary: Some(productImage)}
  | ProductImageAltTextSet({productImage, altText}) => {
      ...state,
      altTexts: state.altTexts
      ->Array.filter(((r, _)) => r != productImage)
      ->Array.concat([(productImage, altText)]),
    }
  | ProductArchived => {...state, shelf: Archived}
  | ProductUnarchived => {...state, shelf: Listed}
  | ProductDiscontinued => {...state, shelf: Discontinued}
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
    Error(ProductNotFound)
  } else if state.shelf == Discontinued {
    Error(ProductIsDiscontinued)
  } else {
    switch command {
    | AttachProductImage({productId, productImage, altText: ?altText}) =>
      state.attached->Array.includes(productImage)
        ? Ok([])
        : Ok([ProductImageAttached({productId, productImage, altText: ?altText})])
    | RemoveProductImage({productId, productImage}) =>
      state.attached->Array.includes(productImage)
        ? Ok([ProductImageRemoved({productId, productImage})])
        : Ok([])
    | SetPrimaryProductImage({productId, productImage}) =>
      if !(state.attached->Array.includes(productImage)) {
        Error(ProductImageNotAttached)
      } else if effectivePrimary(state) == Some(productImage) {
        Ok([])
      } else {
        Ok([ProductPrimaryImageSet({productId, productImage})])
      }
    | SetProductImageAltText({productId, productImage, altText}) =>
      if !(state.attached->Array.includes(productImage)) {
        Error(ProductImageNotAttached)
      } else if altTextOf(state, productImage) == Some(altText) {
        Ok([])
      } else {
        Ok([ProductImageAltTextSet({productId, productImage, altText})])
      }
    }
  }
