// Order event mappings — maps Order events to Order commands.
// When an order is placed, automatically issue a Ship command.

open Reventless

module Target = Order

module AutoShipMapping = {
  module Source = Order
  module Target = Order

  let map = (orderId, event, _queryEngine) =>
    switch event {
    | Order.Placed(_) => [EventMapping.Publish(orderId, Order.Ship)]
    | _ => []
    }
}

module type Mapping = EventMapping.T with module Target := Target

let moduleUrl: string = %raw(`import.meta.url`)
let mappings: array<module(Mapping)> = [module(AutoShipMapping)]

let counter = None
