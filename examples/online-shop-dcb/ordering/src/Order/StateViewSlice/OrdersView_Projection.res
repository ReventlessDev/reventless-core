@@reventless.projection

let project = event =>
  switch event {
  | OrderPlaced({orderId, customerId, productIds}) => [
      Set(orderId, {orderId, customerId, productIds, status: "placed"}),
    ]
  | OrderShipped({orderId}) => [Update(orderId, state => {...state, status: "shipped"})]
  | OrderCancelled({orderId}) => [Update(orderId, state => {...state, status: "cancelled"})]
  }
