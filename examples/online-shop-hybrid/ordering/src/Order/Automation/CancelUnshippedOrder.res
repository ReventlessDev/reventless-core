// CancelUnshippedOrder AutomationSlice.
// A deadline: a Standard order the batch run has not shipped three days after it
// was placed is cancelled. No schedule: the item carries its due time, counted
// from when the order was recorded, and the sweep offers it until that time comes.
//
// Express orders ship at once (`AutoShipOrder`) and Pickup orders are collected
// in store, so only Standard orders wait for a batch that might not come.

@@reventless.spec

@schema
type todoItem = {orderId: OrderId.t, dueAt: float}

@schema
type command = CancelOrder({orderId: OrderId.t})

let maxRetries = 3
let heartbeatInterval = 60
let targetName = "CancelOrder"
