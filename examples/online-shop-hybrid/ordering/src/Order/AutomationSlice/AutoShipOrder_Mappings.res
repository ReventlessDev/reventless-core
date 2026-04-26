// AutoShipOrder mappings — single-source from the ordering plugin's own
// DcbEventLog. Plan 04 moved collect/resolve from `_Automation` into per-source
// mappings; `process` (the source-agnostic command-producer) stays in
// `AutoShipOrder_Automation.res`.

open Reventless.AutomationSlice

// Hand-rolled DcbSource — `name` MUST equal `<pluginName>DcbEventLog` so the
// dispatch in `AutomationSlice_Callback` resolves it to the topic key
// `Plugin_Builder` registers under.
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

    // Single-source self-DCB consumer — tags come from the slice's own
    // command schema (`@compositePartitionTag` / `@s.matches(DcbTag.string)`),
    // not from ambient context. `toTags` is a no-op validator here.
    let toTags = (_item, _ctx) => Ok()
  },
)

// Mappings collection — satisfies `Reventless.AutomationSlice.Mappings with
// module Target := AutoShipOrder`.
module M = Mappings.Make(AutoShipOrder)
module type Mapping = M.Mapping
let moduleUrl: string = %raw(`import.meta.url`)
let mappings: array<module(Mapping)> = [module(FromOrderingDcb)]
