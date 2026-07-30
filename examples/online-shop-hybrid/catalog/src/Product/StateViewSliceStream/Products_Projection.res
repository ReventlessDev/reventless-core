@@reventless.projection

let project = ({event}) =>
  switch event {
  | ProductAdded({productId, name, description, price, imageUrl: ?imageUrl, categoryId}) => [
      Set(productId, {productId, name, description, price, imageUrl: ?imageUrl, categoryId}),
    ]
  | ProductNameChanged({productId, name}) => [Update(productId, state => {...state, name})]
  | ProductDescriptionChanged({productId, description}) => [
      Update(productId, state => {...state, description}),
    ]
  | ProductPriceChanged({productId, price}) => [Update(productId, state => {...state, price})]
  | ProductImageChanged({productId, imageUrl}) => [
      Update(productId, state => {...state, imageUrl}),
    ]
  }
