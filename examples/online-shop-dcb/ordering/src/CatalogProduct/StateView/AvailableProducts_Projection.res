@@reventless.projection

let project = ({event}) =>
  switch event {
  | CatalogProductSynced({productId, name, price}) => [Set(productId, {productId, name, price})]
  | CatalogProductPriceChanged({productId, price}) =>
    [Update(productId, p => {...p, price})]
  }
