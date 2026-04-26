// AutoShipOrder mappings — single-source from the ordering plugin's own
// DcbEventLog. Plan 04 moved collect/resolve from `_Automation` into per-source
// mappings; `process` (the source-agnostic command-producer) stays in
// `AutoShipOrder_Automation.res`.

open Reventless.AutomationSlice

module OrderingDcbSource = {
  module Id = Reventless.Id.String
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
    type tagSet = unit

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

    let toTags = (_item, _ctx) => Ok()
  },
)

module M = Mappings.Make(AutoShipOrder)
module type Mapping = M.Mapping
let moduleUrl: string = %raw(`import.meta.url`)
let mappings: array<module(Mapping)> = [module(FromOrderingDcb)]
