@@reventless.projection

// The primary a reader should show is the first member, so choosing one is
// reordering the set — the trait's rule, applied here over the view's rows. No
// scalar to assign and none to keep in step: attach appends, remove filters, and
// the head moves only where somebody moved it.
let primaryFirst = (state: Products.state, chosen: string) => {
  ...state,
  productImages: TraitAttachments.Attachments_Rules.primaryFirst(
    ~chosen,
    ~members=state.productImages,
    ~ref=a => a.ref,
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
  // Appended, so the first member attached is the primary until one is chosen.
  | ProductImageAttached({productId, productImage, altText: ?altText}) => [
      Update(productId, state =>
        state.productImages->Array.some(a => a.ref == productImage)
          ? state
          : {
              ...state,
              productImages: state.productImages->Array.concat([
                {ref: productImage, altText: ?altText},
              ]),
            }
      ),
    ]
  // Removing the head promotes the next member with no arm to say so.
  | ProductImageRemoved({productId, productImage}) => [
      Update(productId, state => {
        ...state,
        productImages: state.productImages->Array.filter(a => a.ref != productImage),
      }),
    ]
  | ProductPrimaryImageSet({productId, productImage}) => [
      Update(productId, state => primaryFirst(state, productImage)),
    ]
  | ProductImageAltTextSet({productId, productImage, altText}) => [
      Update(productId, state => {
        ...state,
        productImages: state.productImages->Array.map(a =>
          a.ref == productImage ? {...a, altText} : a
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
