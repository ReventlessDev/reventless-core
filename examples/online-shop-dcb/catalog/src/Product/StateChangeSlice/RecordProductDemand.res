// RecordProductDemand StateChangeSlice.
// Records and revokes per-product order demand driven by Ordering's extension point events.
@@reventless.spec

type state = {recordedOrderIds: array<string>}
let initialState = {recordedOrderIds: []}

@schema
type consumedEvent =
  | ProductDemandRecorded({orderId: string})
  | ProductDemandRevoked({orderId: string})

let evolve = (state, event) =>
  switch event {
  | ProductDemandRecorded({orderId}) => {
      recordedOrderIds: Array.concat(state.recordedOrderIds, [orderId]),
    }
  | ProductDemandRevoked({orderId}) => {
      recordedOrderIds: state.recordedOrderIds->Array.filter(id => id !== orderId),
    }
  }

@schema
type command =
  | RecordDemand({productId: string, orderId: string})
  | RevokeDemand({productId: string, orderId: string})

@schema
type error = unit // always succeeds — demand recording is idempotent

@schema
type event =
  | ProductDemandRecorded({
      @partitionTag productId: string,
      orderId: string,
    })
  | ProductDemandRevoked({
      @partitionTag productId: string,
      orderId: string,
    })

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
