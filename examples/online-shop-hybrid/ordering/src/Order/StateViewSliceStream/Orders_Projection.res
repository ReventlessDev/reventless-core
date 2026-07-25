@@reventless.projection

let project = ({event, meta}) =>
  switch event {
  | OrderPlaced({orderId, customerId, productIds, shippingMethod}) => [
      Set(
        orderId,
        {orderId, customerId, productIds, status: Placed, shippingMethod, placedAt: meta.time, shippedAt: ""},
      ),
    ]
  | OrderShipped({orderId}) => [
      Update(orderId, state => {...state, status: Shipped, shippedAt: meta.time}),
    ]
  | OrderCancelled({orderId}) => [Update(orderId, state => {...state, status: Cancelled})]
  }
