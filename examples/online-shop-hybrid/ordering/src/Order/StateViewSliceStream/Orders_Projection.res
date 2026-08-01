@@reventless.projection

let project = ({event, meta}) =>
  switch event {
  | OrderPlaced({orderId, customerId, productIds, shippingMethod, deliveryWindow}) => [
      Set(
        orderId,
        {
          orderId,
          customerId,
          productIds,
          status: Placed,
          shippingMethod,
          placedAt: meta.time,
          shippedAt: "",
          deliveryWindow,
        },
      ),
    ]
  | OrderShipped({orderId}) => [
      Update(orderId, state => {...state, status: Shipped, shippedAt: meta.time}),
    ]
  | OrderCancelled({orderId}) => [Update(orderId, state => {...state, status: Cancelled})]
  }
