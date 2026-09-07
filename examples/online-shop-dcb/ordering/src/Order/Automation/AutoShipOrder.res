// AutoShipOrder AutomationSlice.
// When OrderPlaced is emitted, automatically issue a ShipOrder command.
// Resolved when OrderShipped arrives.
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
