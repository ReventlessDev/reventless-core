@@reventless.projection

// The reference this row holds, if it holds one. Both image guards below ask the
// same question: a removal is the first half of a replacement, and an arm that
// cleared unconditionally would blank the field the second half had just filled.
let heldRef = (state: Categories.state) => state.categoryImage->Option.map(held => held.ref)

let project = ({event}) =>
  switch event {
  | CategoryAdded({categoryId, name}) => [
      Set(categoryId, {categoryId, name, shelfStatus: Listed, trail: []}),
    ]
  | CategoryRenamed({categoryId, name}) => [Update(categoryId, state => {...state, name})]
  | CategoryImageAttached({categoryId, categoryImage, altText: ?altText}) => [
      Update(categoryId, state => {
        ...state,
        categoryImage: {ref: categoryImage, altText: ?altText},
      }),
    ]
  | CategoryImageRemoved({categoryId, categoryImage}) => [
      Update(categoryId, state =>
        heldRef(state) == Some(categoryImage) ? {...state, categoryImage: ?None} : state
      ),
    ]
  | CategoryImageAltTextSet({categoryId, categoryImage, altText}) => [
      Update(categoryId, state =>
        switch state.categoryImage {
        | Some(held) if held.ref == categoryImage => {...state, categoryImage: {...held, altText}}
        | _ => state
        }
      ),
    ]
  | CategoryArchived({categoryId}) => [
      Update(categoryId, state => {...state, shelfStatus: Archived}),
    ]
  | CategoryUnarchived({categoryId}) => [
      Update(categoryId, state => {...state, shelfStatus: Listed}),
    ]
  }
