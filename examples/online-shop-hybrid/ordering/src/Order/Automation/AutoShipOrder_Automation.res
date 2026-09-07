@@reventless.automation

// Single DCB source — events from the ordering plugin's own event log.
// `name` MUST equal `<pluginName>DcbEventLog` so the dispatch in
// `AutomationSlice_Callback` resolves it to the topic key `Plugin_Builder`
// registers under.
module OrderingDcbSource = {
  let name = "OrderingDcbEventLog"

  @schema
  type shippingMethod =
    | Standard
    | Express
    | Pickup

  @schema
  type event =
    | OrderPlaced({orderId: string, shippingMethod: shippingMethod})
    | OrderShipped({orderId: string})
}

module FromOrderingDcb = Mapping.Make(
  OrderingDcbSource,
  AutoShipOrder,
  {
    open OrderingDcbSource

    // Filtering here rather than in `process` is deliberate: a todo row is a
    // claim that this slice owes an action. Admitting Standard and Pickup and
    // then declining them in `process` would leave rows Pending forever, so the
    // todo view would show a backlog that is never worked off.
    let collect = (event, ~sourceId as _, _ctx) =>
      switch event {
      | OrderPlaced({orderId, shippingMethod: Express}) => [
          (orderId, ({orderId: orderId}: AutoShipOrder.todoItem)),
        ]
      | OrderPlaced(_) => []
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

// Nothing to say: an order the shipping automation gave up on is a Placed order
// that never shipped, which the Orders view already shows. A command here would
// be inventing a lifecycle state the domain does not have.
let onExhausted = (_id, _item) => None
