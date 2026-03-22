// ProductDemandView StateViewSlice.
// Projects catalog events into a per-product demand counter (order count).

open Reventless.Projection
open CatalogEventLog

let name = "ProductDemandView"
let moduleUrl: string = %raw(`import.meta.url`)

module DcbEventLogSpec = CatalogEventLog

@schema
type event = CatalogEventLog.event

@schema
type state = {productId: string, name: string, orderCount: int}

let project = (state, event) =>
  switch event {
  | ProductAdded({productId, name}) =>
    switch state {
    | None => [Set(productId, {productId, name, orderCount: 0})]
    | Some(s) => [Set(productId, {...s, name})]
    }
  | ProductDemandRecorded({productId}) =>
    switch state {
    | Some(s) => [Set(productId, {...s, orderCount: s.orderCount + 1})]
    | None => []
    }
  | ProductDemandRevoked({productId}) =>
    switch state {
    | Some(s) => [Set(productId, {...s, orderCount: max(0, s.orderCount - 1)})]
    | None => []
    }
  | _ => []
  }
