// ProductDemandView StateViewSlice.
// Projects catalog events into a per-product demand counter (order count).

@@reventless.spec

open Reventless.Projection

@schema
type consumedEvent =
  | ProductAdded({productId: string, name: string})
  | ProductDemandRecorded({productId: string})
  | ProductDemandRevoked({productId: string})

@schema
type state = {productId: string, name: string, orderCount: int}

let project = event =>
  switch event {
  | ProductAdded({productId, name}) =>
    [UpdateWithDefault(productId, {productId, name, orderCount: 0}, s => {...s, name})]
  | ProductDemandRecorded({productId}) =>
    [Update(productId, s => {...s, orderCount: s.orderCount + 1})]
  | ProductDemandRevoked({productId}) =>
    [Update(productId, s => {...s, orderCount: max(0, s.orderCount - 1)})]
  }
