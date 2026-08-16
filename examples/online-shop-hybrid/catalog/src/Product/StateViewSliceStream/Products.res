// Products StateViewSliceStream.
// Projects product events from the shared catalog event log into a Products read model.

@@reventless.spec

@schema
type consumedEvent =
  | ProductAdded({productId: string, name: string, description: string, price: Reventless.Money.t, imageUrl?: string, categoryId: string})
  | ProductNameChanged({productId: string, name: string})
  | ProductDescriptionChanged({productId: string, description: string})
  | ProductPriceChanged({productId: string, price: Reventless.Money.t})
  | ProductImageChanged({productId: string, imageUrl: string})
  | ProductArchived({productId: string})
  | ProductUnarchived({productId: string})
  | ProductDiscontinued({productId: string})

// Where a product is on the shelf. Two ways off it, and the difference is the
// point: both withdraw the row from ordinary reads identically, and what they
// disagree about is whether it can come back.
//
// `Archived` is reversible — a product pulled from the catalog for a season, or
// while its supplier is sorted out. `@allowedStates([Archived])` on
// `UnarchiveProduct` offers the way back exactly where it exists.
//
// `Discontinued` is not. No command names it as a from-state, so the generated
// lifecycle diagram draws it terminal and no surface offers a way out. A boolean
// could express the exclusion and nothing else; the second state is what carries
// "can this come back", and `@allowedStates` reads it for free.
@schema
type shelfStatus =
  | Listed
  | @retired Archived
  | @retired Discontinued

@schema
type state = {
  productId: string,
  name: string,
  description: string,
  price: Reventless.Money.t,
  @storageRef("productImages") imageUrl?: string,
  // Indexed so the server can answer "the products in this category" — a
  // `categoryIdEq` filter on the connection, rather than a client narrowing one
  // loaded page.
  @index categoryId: string,
  // `@lifecycle` makes this the field commands' `@allowedStates` are written in
  // terms of; the retirements are on the constructors above.
  @lifecycle shelfStatus: shelfStatus,
}
