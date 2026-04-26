@@reventless.projection

let project = event =>
  switch event {
  | OrderPlaced({orderId, customerId, productId}) => [
      Set(orderId, {orderId, customerId, productId, status: "placed"}),
    ]
  | OrderShipped({orderId}) => [Update(orderId, state => {...state, status: "shipped"})]
  | OrderCancelled({orderId}) => [Update(orderId, state => {...state, status: "cancelled"})]
  }
