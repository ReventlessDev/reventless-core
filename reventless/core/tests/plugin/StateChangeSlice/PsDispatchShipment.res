// Test fixture spec for the @transition cross-check — the failing case.
//
// `Dispatchd` is a deliberate typo. It compiles: the PPX strips the attribute
// before the typechecker sees it, so a misspelled state is a well-formed string
// all the way down. That is exactly the hole the structure-side check closes,
// and a fixture that could not compile would not demonstrate it.

@@reventless.spec("DispatchShipment")

type shipmentStatus =
  | Booked
  | Dispatched

@schema
type consumedEvent = ShipmentBooked({shipmentId: string})

let evolve = (_state, _event) => true

type state = bool
let initialState = false

@schema
type command = @transition(([Booked]) => Dispatchd) DispatchShipment({shipmentId: string})

@schema
type error = ShipmentNotFound

@schema
type event = ShipmentDispatched({shipmentId: string})

let decide = (_state, _command): result<array<event>, error> => Ok([])
