// Test fixture spec: one slice carrying commands with different audiences.
// `Restock` is operator-only, `RequestRestock` is open to anyone signed in —
// which is the case a component-level access rule would get wrong.

@@reventless.spec("GatedCommands")

type state = bool
let initialState = false

@schema
type consumedEvent = StockLow({productId: string})

let evolve = (_state, _event) => true

@schema
type command =
  | @authorize(AllowGroups(["Admin", "Ops"])) Restock({productId: string})
  | RequestRestock({productId: string})

@schema
type error = UnknownProduct

@schema
type event =
  | Restocked({productId: string})
  | RestockRequested({productId: string})

let decide = (_state, _command): result<array<event>, error> => Ok([])
