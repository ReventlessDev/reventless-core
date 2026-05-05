@@reventless.projection

let project = event =>
  switch event {
  | OrderPlaced({orderId, customerId, productIds}) => [
      Set(orderId, {orderId, customerId, productIds, status: Placed}),
    ]
  | OrderShipped({orderId}) => [Update(orderId, state => {...state, status: Shipped})]
  | OrderCancelled({orderId}) => [Update(orderId, state => {...state, status: Cancelled})]
  }
