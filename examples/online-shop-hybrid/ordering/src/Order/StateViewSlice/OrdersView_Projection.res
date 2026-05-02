@@reventless.projection

let project = event =>
  switch event {
  | OrderPlaced({orderId, customerId, productId}) => [
      Set(orderId, {orderId, customerId, productId, status: Placed}),
    ]
  | OrderShipped({orderId}) => [Update(orderId, state => {...state, status: Shipped})]
  | OrderCancelled({orderId}) => [Update(orderId, state => {...state, status: Cancelled})]
  }
