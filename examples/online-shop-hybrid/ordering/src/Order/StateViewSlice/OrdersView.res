// OrdersView StateViewSlice.
// Projects order events from the shared ordering event log into an Orders read model.

open Reventless.Projection
open OrderingEventLog

let name = "OrdersView"
let moduleUrl: string = %raw(`import.meta.url`)

module DcbEventLogSpec = OrderingEventLog

@schema
type event = OrderingEventLog.event

@schema
type state = {
  orderId: string,
  customerId: string,
  productIds: array<string>,
  status: string, // "placed" | "shipped" | "cancelled"
}

let project = (_, event) =>
  switch event {
  | OrderPlaced({orderId, customerId, productIds}) => [
      Set(orderId, {orderId, customerId, productIds, status: "placed"}),
    ]
  | OrderShipped({orderId}) => [Update(orderId, state => {...state, status: "shipped"})]
  | OrderCancelled({orderId}) => [Update(orderId, state => {...state, status: "cancelled"})]
  | _ => []
  }
