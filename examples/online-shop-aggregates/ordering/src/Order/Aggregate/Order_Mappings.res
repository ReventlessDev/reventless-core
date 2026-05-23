// Order event mappings — maps Order events to Order commands.
// When an order is placed, automatically issue a Ship command.
@@reventless.mappings

module AutoShipMapping = {
  module Source = Order

  let map = (orderId, event, _queryEngine) =>
    switch event {
    | Order.Placed(_) => [Publish(orderId, Order.Ship)]
    | _ => []
    }
}

let mappings: array<module(Mapping)> = [module(AutoShipMapping)]
