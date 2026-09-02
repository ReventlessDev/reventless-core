@@reventless.behavior

// The set's rules are the trait's; what is left here is the shelf refusal and the
// mapping between this host's constructors and the trait's ops and facts.
module Attachments = TraitAttachments.Attachments_Rules

type shelf = Listed | Archived | Discontinued

type state = {exists: bool, shelf: shelf, images: Attachments.t}

let initialState = {exists: false, shelf: Listed, images: Attachments.empty}

let evolve = (state, event) => {
  let fold = fact => {...state, images: state.images->Attachments.evolve(fact)}
  switch event {
  | ProductAdded => {...state, exists: true}
  | ProductImageAttached({productImage}) => fold(Attached({ref: productImage, altText: None}))
  | ProductImageRemoved({productImage}) => fold(Removed({ref: productImage}))
  | ProductPrimaryImageSet({productImage}) => fold(PrimarySet({ref: productImage}))
  | ProductImageAltTextSet({productImage, altText}) =>
    fold(AltTextSet({ref: productImage, altText}))
  | ProductArchived => {...state, shelf: Archived}
  | ProductUnarchived => {...state, shelf: Listed}
  | ProductDiscontinued => {...state, shelf: Discontinued}
  }
}

let toOp = command =>
  switch command {
  | AttachProductImage({productId, productImage, altText: ?altText}) => (
      productId,
      Attachments.Attach({ref: productImage, altText}),
    )
  | RemoveProductImage({productId, productImage}) => (
      productId,
      Attachments.Remove({ref: productImage}),
    )
  | SetPrimaryProductImage({productId, productImage}) => (
      productId,
      Attachments.SetPrimary({ref: productImage}),
    )
  | SetProductImageAltText({productId, productImage, altText}) => (
      productId,
      Attachments.SetAltText({ref: productImage, altText}),
    )
  }

let toEvent = (productId, fact) =>
  switch fact {
  | Attachments.Attached({ref, altText}) =>
    ProductImageAttached({productId, productImage: ref, altText: ?altText})
  | Attachments.Removed({ref}) => ProductImageRemoved({productId, productImage: ref})
  | Attachments.PrimarySet({ref}) => ProductPrimaryImageSet({productId, productImage: ref})
  | Attachments.AltTextSet({ref, altText}) =>
    ProductImageAltTextSet({productId, productImage: ref, altText})
  }

let decide = (state, command) =>
  if !state.exists {
    Error(ProductNotFound)
  } else if state.shelf == Discontinued {
    Error(ProductIsDiscontinued)
  } else {
    let (productId, op) = toOp(command)
    switch state.images->Attachments.decide(op) {
    | Error(#NotAttached) => Error(ProductImageNotAttached)
    | Ok(None) => Ok([])
    | Ok(Some(fact)) => Ok([toEvent(productId, fact)])
    }
  }
