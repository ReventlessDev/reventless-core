// ChangeProductPrice StateChangeSlice.
// Requires product to exist; idempotent when price is unchanged.

@@reventless.spec

// The shelf events carry no payload here: this slice needs to know *where* the
// product sits, not what changed. Every slice that decides on the shelf consumes
// all three, so a product that comes back is decided on the current fact rather
// than a flag nobody cleared.
@schema
type consumedEvent =
  | ProductAdded({price: Reventless.Money.t})
  | ProductPriceChanged({price: Reventless.Money.t})
  | ProductArchived
  | ProductUnarchived
  | ProductDiscontinued

@schema
type command =
  | @authorize(AllowGroups(["Admin", "Merchandiser"]))
  ChangeProductPrice({productId: string, price: Reventless.Money.t})

@schema
type error =
  | ProductNotFound
  | ProductIsDiscontinued

@schema
type event =
  | ProductPriceChanged({productId: string, price: Reventless.Money.t})

// Repricing is legal on a listed product and on an archived one — a product
// pulled for a season is coming back, and its price should be right when it
// does. It is not legal on a discontinued one, which is terminal. `Guards`
// rather than `Moves`: the price is not where the product sits.
type lifecycleState = Products.shelfStatus

let commandTransition = (command: command): Reventless.Transition.t<lifecycleState> => {
  open Reventless.Transition
  switch command {
  | ChangeProductPrice(_) => Guards([Products.Listed, Products.Archived])
  }
}
