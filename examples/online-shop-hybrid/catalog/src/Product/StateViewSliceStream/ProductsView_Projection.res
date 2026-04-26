@@reventless.projection

let project = event =>
  switch event {
  | ProductAdded({productId, name, description, price}) => [
      Set(productId, {productId, name, description, price}),
    ]
  | ProductNameChanged({productId, name}) => [Update(productId, state => {...state, name})]
  | ProductDescriptionChanged({productId, description}) => [
      Update(productId, state => {...state, description}),
    ]
  | ProductPriceChanged({productId, price}) => [Update(productId, state => {...state, price})]
  }
