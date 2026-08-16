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

// Repricing is legal on a listed product and on an archived one — a product
// pulled for a season is coming back, and its price should be right when it
// does. It is not legal on a discontinued one, which is terminal. Two
// from-states and no target: the price is not where the product sits, so this
// command moves nothing.
@schema
type command =
  | @authorize(AllowGroups(["Admin", "Merchandiser"]))
  @transition([Products.Listed, Products.Archived])
  ChangeProductPrice({productId: string, price: Reventless.Money.t})

@schema
type error =
  | ProductNotFound
  | ProductIsDiscontinued

@schema
type event =
  | ProductPriceChanged({productId: string, price: Reventless.Money.t})
