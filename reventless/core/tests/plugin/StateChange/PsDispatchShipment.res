// Test fixture spec for the declared-edge cross-check — the failing case.
//
// The switch names constructors of THIS file's own enum, and `Dispatchd` is a
// real case of it, so the compiler is satisfied. The linked `Shipments` view
// declares `Booked | Dispatched`, and nothing forces a spec to pick its linked
// view's enum — which is the hole the structure-side check closes, and the half
// the typechecker cannot reach.

@@reventless.spec("DispatchShipment")

type shipmentStatus =
  | Booked
  | Dispatchd

@schema
type consumedEvent = ShipmentBooked({shipmentId: string})

let evolve = (_state, _event) => true

type state = bool
let initialState = false

@schema
type command = DispatchShipment({shipmentId: string})

@schema
type error = ShipmentNotFound

@schema
type event = ShipmentDispatched({shipmentId: string})

let decide = (_state, _command): result<array<event>, error> => Ok([])

type lifecycleState = shipmentStatus

let commandTransition = (command: command): Reventless.Transition.t<lifecycleState> => {
  open Reventless.Transition
  switch command {
  | DispatchShipment(_) => Moves([Booked], Dispatchd)
  }
}
