// Test fixture spec for `commandTransition` — the edge declared as a switch
// rather than as an attribute.
//
// Three cases in one command type:
//
//   `Book`     declares only through the switch, which is the case
//              `@transition` cannot serve for a spliced constructor.
//   `Rebook`   carries BOTH. The switch says `Booked`, the attribute says
//              `Draft`; the switch is what must reach the commandDef, because
//              two sources of truth need a stated winner.
//   `Abandon`  declares nothing in either, and must stay unconstrained.
//
// The states go in as constructors of this file's own enum, so the compiler
// resolves them. `@transition` on `Rebook` cannot — it is stripped before the
// typechecker runs, which is why `PsDispatchShipment` can carry a typo at all.

@@reventless.spec("TransitionSwitch")

type bookingStatus = Draft | Booked | Abandoned

@schema
type consumedEvent = BookingDrafted({bookingId: string})

let evolve = (_state, _event) => true

type state = bool
let initialState = false

@schema
type command =
  | Book({bookingId: string})
  | @transition(([Draft]) => Draft) Rebook({bookingId: string})
  | Abandon({bookingId: string})

@schema
type error = BookingNotFound

@schema
type event = BookingBooked({bookingId: string}) | BookingAbandoned({bookingId: string})

let decide = (_state, _command): result<array<event>, error> => Ok([])

type lifecycleState = bookingStatus

let commandTransition = (command: command): Reventless.Transition.t<lifecycleState> => {
  open Reventless.Transition
  switch command {
  | Book(_) => Moves([Draft], Booked)
  | Rebook(_) => Guards([Booked])
  | Abandon(_) => Unrestricted
  }
}

// Declared, so the structure has a graft to record. The value stands in for a
// trait package's own `declaration` — a fixture cannot depend on one, and what is
// under test is the collection, not where the value came from.
let traits: array<Reventless.Trait.t> = [
  {trait: "@reventlessdev/trait-booking", version: "9.9.9", posture: SelfContained},
]
