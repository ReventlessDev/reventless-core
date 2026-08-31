@@reventless.projection

// The fallback to the first attached is the trait's rule, applied here over the
// view's own rows so a card never shows no image while the set holds one.
let withPrimary = (state: Products.state, chosen: option<string>) => {
  ...state,
  productImage: ?TraitFileAttachment.FileAttachment_Set.primaryOf(
    ~chosen,
    ~attached=state.productImages->Array.map(a => a.productImage),
  ),
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
      Update(productId, state => {...state, productImage}),
    ]
  | ProductImageAltTextSet({productId, productImage, altText}) => [
      Update(productId, state => {
        ...state,
        productImages: state.productImages->Array.map(a =>
          a.productImage == productImage ? {...a, altText} : a
        ),
      }),
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
