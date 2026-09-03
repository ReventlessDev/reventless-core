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
  | CategoryImageAltTextSet({categoryImage, altText}) =>
    fold(AltTextSet({ref: categoryImage, altText}))
  | CategoryArchived => {...state, archived: true}
  | CategoryUnarchived => {...state, archived: false}
  }
}

// The two ref-less commands map onto the two ref-less ops. Neither has to look
// the image up: resolving "whichever one is held" is the trait's job, and doing
// it here would be a second copy of a rule the conformance suite asserts once.
let toOp = command =>
  switch command {
  | SetCategoryImage({categoryId, categoryImage, altText: ?altText}) => (
      categoryId,
      Attachments.Attach({ref: categoryImage, altText}),
    )
  | RemoveCategoryImage({categoryId}) => (categoryId, Attachments.Clear)
  | SetCategoryImageAltText({categoryId, altText}) => (
      categoryId,
      Attachments.SetPrimaryAltText({altText: altText}),
    )
  }

let toEvent = (categoryId, fact) =>
  switch fact {
  | Attachments.Attached({ref, altText}) =>
    Some(CategoryImageAttached({categoryId, categoryImage: ref, altText: ?altText}))
  | Attachments.Removed({ref}) => Some(CategoryImageRemoved({categoryId, categoryImage: ref}))
  // Unreachable: no command of this graft chooses a primary, because one image
  // is nothing to choose between. It contributes no event rather than being
  // fabricated into some other one to keep the switch total.
  | Attachments.PrimarySet(_) => None
  | Attachments.AltTextSet({ref, altText}) =>
    Some(CategoryImageAltTextSet({categoryId, categoryImage: ref, altText}))
  }

let decide = (state, command) =>
  if !state.exists {
    Error(CategoryNotFound)
  } else if state.archived {
    Error(CategoryAlreadyArchived)
  } else {
    let (categoryId, op) = toOp(command)
    switch state.images->Attachments.decide(~cardinality=Single, op) {
    | Error(#NotAttached) => Error(CategoryImageNotAttached)
    | Ok(facts) => Ok(facts->Array.filterMap(toEvent(categoryId, _)))
    }
  }
