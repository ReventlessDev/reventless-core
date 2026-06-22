// Test fixture spec for Phase 2 pluginStructure validation.
// ShipOrder SCS: consumes payload-less events (excluded by extractVariantNames),
// produces OrderShipped. orderId in the command gets auto-tagged (Instance-level).

@@reventless.spec("ShipOrder")

type state = bool
let initialState = false

// All payload-less — extractVariantNames will return [] for these.
@schema
type consumedEvent = OrderPlaced | OrderShipped | OrderCancelled

let evolve = (_state, _event) => true

// CancelShipment is payload-less — it compiles to a bare string literal, so it
// exercises toCommandDef's payload-less branch (still surfaced in `commands`).
@schema
type command = ShipOrder({orderId: string}) | CancelShipment

@schema
type error = OrderNotFound

// ShipmentVoided is payload-less — excluded from producedEventTypes (DCB filter),
// but still surfaced in `events` (toEventDef's payload-less branch).
@schema
type event = OrderShipped({orderId: string}) | ShipmentVoided

let decide = (_state, _command): result<array<event>, error> => Ok([])
