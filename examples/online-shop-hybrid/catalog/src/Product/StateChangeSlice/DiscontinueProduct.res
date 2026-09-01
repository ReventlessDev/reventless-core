// DiscontinueProduct StateChangeSlice.
// Takes a product off the shelf for good. Idempotent if already discontinued,
// and allowed from either live state — a product can be discontinued straight
// out of the catalog or after a spell in the archive.
//
// There is deliberately no way back. `Discontinued` names no from-state on any
// command, so the generated lifecycle diagram draws it terminal and no surface
// offers an exit.
@@reventless.spec

@schema
type consumedEvent =
  | ProductAdded
  | ProductArchived
  | ProductUnarchived
  | ProductDiscontinued

@schema
type command =
  | @authorize(AllowGroups(["Admin", "Merchandiser"])) DiscontinueProduct({productId: string})

@schema
type error = ProductNotFound

@schema
type event = ProductDiscontinued({productId: string})

// Both live states, because the decision is about the product's future rather
// than about where it sits today.
type lifecycleState = Products.shelfStatus

let commandTransition = (command: command): Reventless.Transition.t<lifecycleState> => {
  open Reventless.Transition
  switch command {
  | DiscontinueProduct(_) =>
    Moves([Products.Listed, Products.Archived], Products.Discontinued)
  }
}
