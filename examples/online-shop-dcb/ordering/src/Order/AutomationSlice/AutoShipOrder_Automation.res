@@reventless.automation

// Single DCB source — events from the ordering plugin's own event log.
module OrderingDcbSource = {
  let name = "OrderingDcbEventLog"
  @schema
  type event =
    | OrderPlaced({orderId: string})
    | OrderShipped({orderId: string})
}

module FromOrderingDcb = Mapping.Make(
  OrderingDcbSource,
  AutoShipOrder,
  {
    open OrderingDcbSource

    let collect = (event, _ctx) =>
      switch event {
      | OrderPlaced({orderId}) => [(orderId, ({orderId: orderId}: AutoShipOrder.todoItem))]
      | OrderShipped(_) => []
      }

    let resolve = event =>
      switch event {
      | OrderShipped({orderId}) => Some(orderId)
      | OrderPlaced(_) => None
      }
  },
)

let mappings: array<module(Mapping)> = [module(FromOrderingDcb)]

let process = (id, _item) => Some((id, ShipOrder({orderId: id})))
