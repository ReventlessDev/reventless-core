// ProductDemandView StateViewSlice.
// Projects catalog events into a per-product demand counter (order count).
@@reventless.spec

@schema
type state = {productId: string, name: string, orderCount: int}

@schema
type consumedEvent =
  | ProductAdded({productId: string, name: string})
  | ProductDemandRecorded({productId: string})
  | ProductDemandRevoked({productId: string})
