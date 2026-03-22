// RecordProductDemand StateChangeSlice.
// Records and revokes per-product order demand driven by Ordering's extension point events.

open Reventless
open CatalogEventLog

let name = "RecordProductDemand"
let moduleUrl: string = %raw(`import.meta.url`)

module DcbEventLogSpec = CatalogEventLog

@schema
type command =
  | RecordDemand({productId: @s.matches(DcbTag.string) string, orderId: string})
  | RevokeDemand({productId: @s.matches(DcbTag.string) string, orderId: string})

@schema
type error = unit // always succeeds — demand recording is idempotent

type decisionModel = {recordedOrderIds: array<string>}
let initialDecisionModel = {recordedOrderIds: []}

let reduce = (model, event) =>
  switch event {
  | ProductDemandRecorded({orderId}) => {
      recordedOrderIds: Array.concat(model.recordedOrderIds, [orderId]),
    }
  | ProductDemandRevoked({orderId}) => {
      recordedOrderIds: model.recordedOrderIds->Array.filter(id => id !== orderId),
    }
  | _ => model
  }

let decide = (model, command) =>
  switch command {
  | RecordDemand({productId, orderId}) =>
    if model.recordedOrderIds->Array.includes(orderId) {
      Ok([]) // idempotent
    } else {
      Ok([ProductDemandRecorded({productId, orderId})])
    }
  | RevokeDemand({productId, orderId}) =>
    if !(model.recordedOrderIds->Array.includes(orderId)) {
      Ok([]) // idempotent
    } else {
      Ok([ProductDemandRevoked({productId, orderId})])
    }
  }
