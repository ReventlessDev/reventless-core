// ArchiveProduct StateChangeSlice.
// Pulls a product from the catalog without deleting it; idempotent if already
// archived. Reversible — see `UnarchiveProduct`.
@@reventless.spec

@schema
type consumedEvent =
  | ProductAdded
  // Without this the slice's own `shelfStatus` goes stale the moment a product
  // returns to the catalog, and archiving it a second time reads as a repeat and
  // is swallowed. Every slice that decides on this state consumes all of them.
  | ProductArchived
  | ProductUnarchived
  | ProductDiscontinued

@schema
type command =
  // Meaningful only on a product still on the shelf. `@transition` names states
  // of the view's lifecycle, which is the same field the retirement is declared
  // on — one vocabulary, so a menu offers this and `UnarchiveProduct` on
  // opposite sides of the same fact.
  | @authorize(AllowGroups(["Admin", "Merchandiser"]))
  @transition(([Products.Listed]) => Products.Archived)
  ArchiveProduct({productId: string})

// Refused rather than idempotent: `Discontinued` is terminal, and archiving out
// of it would quietly make it reversible — the one thing the second state exists
// to say it is not.
@schema
type error = ProductNotFound | ProductIsDiscontinued

@schema
type event = ProductArchived({productId: string})
