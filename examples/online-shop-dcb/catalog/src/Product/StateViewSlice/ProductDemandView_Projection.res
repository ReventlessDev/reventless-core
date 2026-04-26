@@reventless.projection

let project = event =>
  switch event {
  | ProductAdded({productId, name}) =>
    [UpdateWithDefault(productId, {productId, name, orderCount: 0}, s => {...s, name})]
  | ProductDemandRecorded({productId}) =>
    [Update(productId, s => {...s, orderCount: s.orderCount + 1})]
  | ProductDemandRevoked({productId}) =>
    [Update(productId, s => {...s, orderCount: max(0, s.orderCount - 1)})]
  }
