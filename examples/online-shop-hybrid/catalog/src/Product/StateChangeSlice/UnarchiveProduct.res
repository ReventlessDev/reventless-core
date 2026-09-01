// UnarchiveProduct StateChangeSlice.
// The way back onto the shelf. Requires the product to exist; idempotent if it
// is already listed, and refused on a discontinued one.
//
// This slice is what makes `Archived` and `Discontinued` two states rather than
// one: they withdraw the row identically, and only the existence of a command
// naming one of them as a from-state says which withdrawal can be undone.
@@reventless.spec

@schema
type consumedEvent =
  | ProductAdded
  | ProductArchived
  | ProductUnarchived
  | ProductDiscontinued

@schema
type command =
  | @authorize(AllowGroups(["Admin", "Merchandiser"])) UnarchiveProduct({productId: string})

@schema
type error = ProductNotFound | ProductIsDiscontinued

@schema
type event = ProductUnarchived({productId: string})

// The edge that makes the two withdrawals different: this is the only command
// naming `Archived` as a from-state, so a diagram draws the way back from there
// and none out of `Discontinued`.
type lifecycleState = Products.shelfStatus

let commandTransition = (command: command): Reventless.Transition.t<lifecycleState> => {
  open Reventless.Transition
  switch command {
  | UnarchiveProduct(_) => Moves([Products.Archived], Products.Listed)
  }
}
