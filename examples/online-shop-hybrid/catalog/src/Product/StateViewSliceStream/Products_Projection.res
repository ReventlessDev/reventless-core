@@reventless.projection

let project = ({event}) =>
  switch event {
  | ProductAdded({productId, name, description, price, imageUrl: ?imageUrl, categoryId}) => [
      Set(
        productId,
        {productId, name, description, price, imageUrl: ?imageUrl, categoryId, shelfStatus: Listed},
      ),
    ]
  | ProductNameChanged({productId, name}) => [Update(productId, state => {...state, name})]
  | ProductDescriptionChanged({productId, description}) => [
      Update(productId, state => {...state, description}),
    ]
  | ProductPriceChanged({productId, price}) => [Update(productId, state => {...state, price})]
  | ProductImageChanged({productId, imageUrl}) => [
      Update(productId, state => {...state, imageUrl}),
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
