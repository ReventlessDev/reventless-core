@@reventless.projection

let project = ({event}) =>
  switch event {
  | OrderPlaced({orderId, customerId, productIds}) => [
      Set(orderId, {orderId, customerId, productIds, lifecycle: Placed}),
    ]
  | OrderShipped({orderId}) => [Update(orderId, state => {...state, lifecycle: Shipped})]
  | OrderCancelled({orderId}) => [Update(orderId, state => {...state, lifecycle: Cancelled})]
  }
