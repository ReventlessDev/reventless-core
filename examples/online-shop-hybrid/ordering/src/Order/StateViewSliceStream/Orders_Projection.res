@@reventless.projection

let project = ({event, meta}) =>
  switch event {
  | OrderPlaced({orderId, customerId, productIds, shippingMethod, deliveryWindow, firstProductName, firstProductImage}) => [
      Set(
        orderId,
        {
          orderId,
          customerId,
          productIds,
          lifecycle: Placed,
          shippingMethod,
          placedAt: meta.time,
          shippedAt: "",
          deliveryWindow,
          // Copied straight through. The event is the record of what was bought;
          // this view does not go and ask the catalog what the product is called
          // now, which is the whole point of freezing it at placement.
          firstProductName,
          firstProductImage,
        },
      ),
    ]
  | OrderShipped({orderId}) => [
      Update(orderId, state => {...state, lifecycle: Shipped, shippedAt: meta.time}),
    ]
  | OrderCancelled({orderId}) => [Update(orderId, state => {...state, lifecycle: Cancelled})]
  // Back to `Placed`, which is where a reopened order is: shippable again, and
  // not carrying a `shippedAt` it never earned.
  | OrderReopened({orderId}) => [Update(orderId, state => {...state, lifecycle: Placed})]
  }
