// AutoShipOrder AutomationSlice.
// Expedited dispatch: when an Express order is placed, issue ShipOrder without
// waiting for the batch run. Resolved when OrderShipped arrives.
//
// Standard orders ship with the batch (an explicit ShipOrder) and Pickup orders
// are collected in store, so neither is this slice's business — `collect` in the
// sibling `_Automation.res` admits only Express.
//
// Consumed events come from per-source `Mapping.Make` modules in the sibling
// `_Automation.res`. The framework derives the consumed-event set from each
// mapping's `sourceEventSchema` — no manual union here.

@@reventless.spec

@schema
type todoItem = {orderId: string}

@schema
type command = ShipOrder({orderId: string})

let maxRetries = 3
let heartbeatInterval = 60
let targetName = "ShipOrder"
