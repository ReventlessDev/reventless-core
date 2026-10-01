// Test fixture spec: one slice carrying commands with different audiences.
// `Restock` is operator-only, `RequestRestock` is open to anyone signed in —
// which is the case a component-level access rule would get wrong.

@@reventless.spec("GatedCommands")

// Declared here rather than in the package's `Roles.res`: the rule resolves
// `Roles` by ordinary scoping, so a spec can name roles its package does not.
module Roles = {
  type t =
    | Admin
    | Ops
}

type state = bool
let initialState = false

@schema
type consumedEvent = StockLow({productId: string})

let evolve = (_state, _event) => true

@schema
type command =
  | @authorize(AllowRoles([Admin, Ops])) Restock({productId: string})
  | RequestRestock({productId: string})

@schema
type error = UnknownProduct

@schema
type event =
  | Restocked({productId: string})
  | RestockRequested({productId: string})

let decide = (_state, _command): result<array<event>, error> => Ok([])
