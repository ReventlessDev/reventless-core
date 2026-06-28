// SendOrderConfirmation OutboundTranslationSlice.
// When OrderPlaced is emitted, sends a confirmation email via EmailService.
// Fire-and-forget pattern (no inbound command).

@@reventless.spec

@schema
type consumedEvent =
  | OrderPlaced({orderId: string, customerId: string})

@schema
type outboundItem = {orderId: string, customerId: string}

@schema
type inboundCommand = unit

let maxRetries = 3
let heartbeatInterval = 60
let targetName = None
// Foreign system this anti-corruption slice publishes confirmations to — drawn as an
// external box outside the Ordering plugin in the Event Graph.
let externalSystem = Some("EmailService")
