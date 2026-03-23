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

type state = {recordedOrderIds: array<string>}
let initialState = {recordedOrderIds: []}

let evolve = (state, event) =>
  switch event {
  | ProductDemandRecorded({orderId}) => {
      recordedOrderIds: Array.concat(state.recordedOrderIds, [orderId]),
    }
  | ProductDemandRevoked({orderId}) => {
      recordedOrderIds: state.recordedOrderIds->Array.filter(id => id !== orderId),
    }
  | _ => state
  }

let decide = (state, command) =>
  switch command {
  | RecordDemand({productId, orderId}) =>
    if state.recordedOrderIds->Array.includes(orderId) {
      Ok([]) // idempotent
    } else {
      Ok([ProductDemandRecorded({productId, orderId})])
    }
  | RevokeDemand({productId, orderId}) =>
    if !(state.recordedOrderIds->Array.includes(orderId)) {
      Ok([]) // idempotent
    } else {
      Ok([ProductDemandRevoked({productId, orderId})])
    }
  }
