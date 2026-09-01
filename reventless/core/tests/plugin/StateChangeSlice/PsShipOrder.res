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

// The lifecycle this slice's commands move a shipment through. Declared here
// rather than on a linked view because this fixture's plugin has none: the
// structure-side check warns instead of failing when a component's views declare
// no lifecycle, and that is the path this exercises.
type shipmentStatus = Placed | Shipped | Cancelled

// CancelShipment is payload-less — it compiles to a bare string literal, so it
// exercises toCommandDef's payload-less branch (still surfaced in `commands`).
// It is also `@noApi` (internal/admin only): a two-variant slice with exactly
// one API-exposed command, which is the case that used to leak the exposed
// command's slice mutation field onto the non-exposed variant. It declares no
// edge, which is the case the board resolver still guesses for.
@schema
type command =
  | ShipOrder({orderId: string})
  | @noApi CancelShipment

// Two variants, one payload-less and one carrying a field — the same two branches
// `events` exercises, so the structure's `errors` list is pinned on both.
@schema
type error = OrderNotFound | NotShippable({reason: string})

// ShipmentVoided is payload-less — excluded from producedEventTypes (DCB filter),
// but still surfaced in `events` (toEventDef's payload-less branch).
@schema
type event = OrderShipped({orderId: string}) | ShipmentVoided

let decide = (_state, _command): result<array<event>, error> => Ok([])

type lifecycleState = shipmentStatus

let commandTransition = (command: command): Reventless.Transition.t<lifecycleState> => {
  open Reventless.Transition
  switch command {
  | ShipOrder(_) => Moves([Placed], Shipped)
  | CancelShipment => Unrestricted
  }
}
