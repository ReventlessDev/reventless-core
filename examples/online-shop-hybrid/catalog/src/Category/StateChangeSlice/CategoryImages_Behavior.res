@@reventless.behavior

// The set's rules are the trait's; what is left here is the archived refusal and
// the mapping between this host's constructors and the trait's ops and facts.
module Attachments = TraitAttachments.Attachments_Rules

type state = {exists: bool, archived: bool, images: Attachments.t}

let initialState = {exists: false, archived: false, images: Attachments.empty}

let evolve = (state, event) => {
  let fold = fact => {...state, images: state.images->Attachments.evolve(fact)}
  switch event {
  | CategoryAdded => {...state, exists: true, archived: false}
  | CategoryImageAttached({categoryImage}) => fold(Attached({ref: categoryImage, altText: None}))
  | CategoryImageRemoved({categoryImage}) => fold(Removed({ref: categoryImage}))
  | CategoryPrimaryImageSet({categoryImage}) => fold(PrimarySet({ref: categoryImage}))
  | CategoryImageAltTextSet({categoryImage, altText}) =>
    fold(AltTextSet({ref: categoryImage, altText}))
  | CategoryArchived => {...state, archived: true}
  | CategoryUnarchived => {...state, archived: false}
  }
}

let toOp = command =>
  switch command {
  | AttachCategoryImage({categoryId, categoryImage, altText: ?altText}) => (
      categoryId,
      Attachments.Attach({ref: categoryImage, altText}),
    )
  | RemoveCategoryImage({categoryId, categoryImage}) => (
      categoryId,
      Attachments.Remove({ref: categoryImage}),
    )
  | SetPrimaryCategoryImage({categoryId, categoryImage}) => (
      categoryId,
      Attachments.SetPrimary({ref: categoryImage}),
    )
  | SetCategoryImageAltText({categoryId, categoryImage, altText}) => (
      categoryId,
      Attachments.SetAltText({ref: categoryImage, altText}),
    )
  }

let toEvent = (categoryId, fact) =>
  switch fact {
  | Attachments.Attached({ref, altText}) =>
    CategoryImageAttached({categoryId, categoryImage: ref, altText: ?altText})
  | Attachments.Removed({ref}) => CategoryImageRemoved({categoryId, categoryImage: ref})
  | Attachments.PrimarySet({ref}) => CategoryPrimaryImageSet({categoryId, categoryImage: ref})
  | Attachments.AltTextSet({ref, altText}) =>
    CategoryImageAltTextSet({categoryId, categoryImage: ref, altText})
  }

let decide = (state, command) =>
  if !state.exists {
    Error(CategoryNotFound)
  } else if state.archived {
    Error(CategoryAlreadyArchived)
  } else {
    let (categoryId, op) = toOp(command)
    switch state.images->Attachments.decide(op) {
    | Error(#NotAttached) => Error(CategoryImageNotAttached)
    | Ok(None) => Ok([])
    | Ok(Some(fact)) => Ok([toEvent(categoryId, fact)])
    }
  }
