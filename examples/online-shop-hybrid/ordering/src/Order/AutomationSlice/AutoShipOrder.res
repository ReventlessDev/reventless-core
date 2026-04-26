// AutoShipOrder AutomationSlice.
// When OrderPlaced is emitted, automatically issue a ShipOrder command.
// Resolved when OrderShipped arrives.
//
// Plan 04: consumed events now come from sibling `_Mappings.res` (one Mapping
// per source). The framework derives the consumed-event set from each
// mapping's `sourceEventSchema` — no manual union here.

@@reventless.spec

@schema
type todoItem = {orderId: string}

@schema
type command = ShipOrder({orderId: string})

let maxRetries = 3
let heartbeatInterval = 60
let targetName = "ShipOrder"
