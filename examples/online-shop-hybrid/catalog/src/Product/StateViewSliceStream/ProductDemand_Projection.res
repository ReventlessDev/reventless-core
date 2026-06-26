@@reventless.projection

let project = event =>
  switch event {
  | ProductAdded({productId, name, categoryId}) =>
    [UpdateWithDefault(productId, {productId, name, categoryId, orderCount: 0}, s => {...s, name, categoryId})]
  | ProductDemandRecorded({productId}) =>
    [Update(productId, s => {...s, orderCount: s.orderCount + 1})]
  | ProductDemandRevoked({productId}) =>
    [Update(productId, s => {...s, orderCount: max(0, s.orderCount - 1)})]
  }
