// Test fixture spec for `commandTransition` — the three shapes of a declared
// edge, in one command type:
//
//   `Book`     moves the row: a from-set and a target.
//   `Rebook`   guards only: a from-set and no target, which is the positive
//              claim that the command moves the row nowhere.
//   `Abandon`  declares nothing, and must stay unconstrained.
//
// The states go in as constructors of this file's own enum, so the compiler
// resolves them.

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
  | Rebook({bookingId: string})
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
