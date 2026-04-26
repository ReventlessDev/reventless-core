// AutoShipOrder AutomationSlice.
// When OrderPlaced is emitted, automatically issue a ShipOrder command.
// Resolved when OrderShipped arrives.

@@reventless.spec

@schema
type consumedEvent =
  | OrderPlaced({orderId: string})
  | OrderShipped({orderId: string})

@schema
type todoItem = {orderId: string}

@schema
type command = ShipOrder({orderId: string})

let maxRetries = 3
let heartbeatInterval = 60
let targetName = "ShipOrder"
