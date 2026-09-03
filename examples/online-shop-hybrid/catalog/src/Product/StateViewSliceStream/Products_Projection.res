@@reventless.projection

// The primary a reader should show and the caption that goes with it: the chosen
// member, else the first attached — the trait's own rule, applied here over the
// view's rows so a card never shows no image while the set holds one. Every arm
// below goes through this rather than assigning the scalar itself, so the two
// cannot drift apart on one arm and not another.
let withPrimary = (state: Products.state, chosen: option<string>) => {
  let (productImage, productImageAltText) = TraitAttachments.Attachments_Rules.primaryWithAltText(
    ~chosen,
    ~members=state.productImages,
    ~ref=a => a.productImage,
    ~altText=a => a.altText,
  )
  {...state, productImage: ?productImage, productImageAltText: ?productImageAltText}
}

let project = ({event}) =>
  switch event {
  | ProductAdded({productId, name, description, price, categoryId}) => [
      Set(
        productId,
        {productId, name, description, price, productImages: [], categoryId, shelfStatus: Listed},
      ),
    ]
  | ProductNameChanged({productId, name}) => [Update(productId, state => {...state, name})]
  | ProductDescriptionChanged({productId, description}) => [
      Update(productId, state => {...state, description}),
    ]
  | ProductPriceChanged({productId, price}) => [Update(productId, state => {...state, price})]
  | ProductImageAttached({productId, productImage, altText: ?altText}) => [
      Update(productId, state =>
        state.productImages->Array.some(a => a.productImage == productImage)
          ? state
          : withPrimary(
              {
                ...state,
                productImages: state.productImages->Array.concat([{productImage, altText: ?altText}]),
              },
              state.productImage,
            )
      ),
    ]
  | ProductImageRemoved({productId, productImage}) => [
      Update(productId, state =>
        withPrimary(
          {...state, productImages: state.productImages->Array.filter(a => a.productImage != productImage)},
          state.productImage == Some(productImage) ? None : state.productImage,
        )
      ),
    ]
  | ProductPrimaryImageSet({productId, productImage}) => [
      Update(productId, state => withPrimary(state, Some(productImage))),
    ]
  // Through `withPrimary` like every other arm: captioning the member that
  // happens to be the primary has to reach the scalar's caption too, and an arm
  // that only rewrote the set's row is how the hero image ended up with none.
  | ProductImageAltTextSet({productId, productImage, altText}) => [
      Update(productId, state =>
        withPrimary(
          {
            ...state,
            productImages: state.productImages->Array.map(a =>
              a.productImage == productImage ? {...a, altText} : a
            ),
          },
          state.productImage,
        )
      ),
    ]
  // The row stays and moves along its lifecycle rather than being deleted: an
  // order still references a withdrawn product, and a merchandiser still needs
  // to find it. Which callers see it afterwards is the resolvers' answer, not
  // this projection's.
  | ProductArchived({productId}) => [
      Update(productId, state => {...state, shelfStatus: Archived}),
    ]
  | ProductUnarchived({productId}) => [Update(productId, state => {...state, shelfStatus: Listed})]
  | ProductDiscontinued({productId}) => [
      Update(productId, state => {...state, shelfStatus: Discontinued}),
    ]
  }
