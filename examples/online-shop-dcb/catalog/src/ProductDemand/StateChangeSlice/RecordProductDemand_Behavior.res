@@reventless.behavior

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
