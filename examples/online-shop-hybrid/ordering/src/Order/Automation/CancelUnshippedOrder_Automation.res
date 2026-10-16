@@reventless.automation

module OrderingDcbSource = {
  let name = "OrderingDcbEventLog"

  @schema
  type shippingMethod =
    | Standard
    | Express
    | Pickup

  @schema
  type event =
    | OrderPlaced({orderId: OrderId.t, shippingMethod: shippingMethod})
    | OrderShipped({orderId: OrderId.t})
    | OrderCancelled({orderId: OrderId.t})
}

/** How long a Standard order may wait for the batch. */
let shippingWindowMs =
  3. *. 24. *. 60. *. 60. *. 1000.

module FromOrderingDcb = Mapping.Make(
  OrderingDcbSource,
  CancelUnshippedOrder,
  {
    open OrderingDcbSource

    // The due time is counted from when the order was recorded, which the runtime
    // gives every event it delivers.
    let collect = (event, ~sourceId as _, ctx: Reventless.AutomationSlice.context) =>
      switch (event, ctx.recordedAt) {
      | (OrderPlaced({orderId, shippingMethod: Standard}), Some(placedAt)) => [
          (
            orderId->OrderId.toString,
            ({orderId, dueAt: placedAt +. shippingWindowMs}: CancelUnshippedOrder.todoItem),
          ),
        ]
      | _ => []
      }

    // Shipped or cancelled in time: nothing is sent.
    let resolve = event =>
      switch event {
      | OrderShipped({orderId}) | OrderCancelled({orderId}) => Some(orderId->OrderId.toString)
      | OrderPlaced(_) => None
      }
  },
)

let mappings: array<module(Mapping)> = [module(FromOrderingDcb)]

// Not yet due is not a failure: the item stays pending and the next sweep offers it
// again. A cancel that comes too late, after the order shipped, is refused by
// `CancelOrder` itself.
let process = (id, item: CancelUnshippedOrder.todoItem, ~now) =>
  now >= item.dueAt ? Some((id, CancelOrder({orderId: item.orderId}))) : None

// The order stays placed, which the Orders view already shows.
let onExhausted = (_id, _item) => None
