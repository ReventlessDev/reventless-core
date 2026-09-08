@@reventless.projection

let project = ({event, meta}) =>
  switch event {
  | OrderPlaced({
      orderId,
      customerId,
      productIds,
      lines,
      total,
      shippingMethod,
      deliveryWindow,
      firstProductName,
      firstProductImage,
    }) => [
      Set(
        orderId,
        {
          orderId,
          customerId,
          productIds,
          lines,
          total,
          // Summed here rather than carried on the event: it is a restatement of
          // the lines, and a projection that derives it cannot disagree with them.
          itemCount: lines->Array.reduce(0, (count, line) => count + line.quantity),
          lifecycle: Placed,
          shippingMethod,
          placedAt: meta.time,
          // Opened by the machinery from this envelope's time, like every later
          // entry — the projection never appends to it by hand.
          trail: [],
          deliveryWindow,
          // Copied straight through. The event is the record of what was bought;
          // this view does not go and ask the catalog what the product is called
          // now, which is the whole point of freezing it at placement.
          firstProductName,
          firstProductImage,
        },
      ),
    ]
  | OrderShipped({orderId}) => [Update(orderId, state => {...state, lifecycle: Shipped})]
  | OrderCancelled({orderId}) => [Update(orderId, state => {...state, lifecycle: Cancelled})]
  // Back to `Placed`, which is where a reopened order is: shippable again, and
  // carrying both visits to `Placed` in its trail.
  | OrderReopened({orderId}) => [Update(orderId, state => {...state, lifecycle: Placed})]
  }
