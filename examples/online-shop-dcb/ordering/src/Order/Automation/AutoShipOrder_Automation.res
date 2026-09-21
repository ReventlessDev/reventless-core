@@reventless.automation

// Single DCB source — events from the ordering plugin's own event log.
module OrderingDcbSource = {
  let name = "OrderingDcbEventLog"
  @schema
  type event =
    | OrderPlaced({orderId: OrderId.t})
    | OrderShipped({orderId: OrderId.t})
}

module FromOrderingDcb = Mapping.Make(
  OrderingDcbSource,
  AutoShipOrder,
  {
    open OrderingDcbSource

    let collect = (event, ~sourceId as _, _ctx) =>
      switch event {
      // To-do rows are keyed by string; the item keeps the typed id.
      | OrderPlaced({orderId}) => [
          (orderId->OrderId.toString, ({orderId: orderId}: AutoShipOrder.todoItem)),
        ]
      | OrderShipped(_) => []
      }

    let resolve = event =>
      switch event {
      | OrderShipped({orderId}) => Some(orderId->OrderId.toString)
      | OrderPlaced(_) => None
      }
  },
)

let mappings: array<module(Mapping)> = [module(FromOrderingDcb)]

let process = (id, item: AutoShipOrder.todoItem) => Some((id, ShipOrder({orderId: item.orderId})))

// Nothing to say: an order the shipping automation gave up on is a Placed order
// that never shipped, which the Orders view already shows. A command here would
// be inventing a lifecycle state the domain does not have.
let onExhausted = (_id, _item) => None
