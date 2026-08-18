// Products StateViewSliceStream.
// Projects product events from the shared catalog event log into a Products read model.

@@reventless.spec

// Order is load-bearing: sury strands constructors declared after a run of two or
// more same-shaped ones, so the `Money.t` pair must lead (DZakh/sury#392).
@schema
type consumedEvent =
  | ProductAdded({productId: string, name: string, description: string, price: Reventless.Money.t, productImage?: string, categoryId: string})
  | ProductPriceChanged({productId: string, price: Reventless.Money.t})
  | ProductNameChanged({productId: string, name: string})
  | ProductDescriptionChanged({productId: string, description: string})
  | ProductImageChanged({productId: string, productImage: string})
  | ProductArchived({productId: string})
  | ProductUnarchived({productId: string})
  | ProductDiscontinued({productId: string})

// Where a product is on the shelf. Two ways off it, and the difference is the
// point: both withdraw the row from ordinary reads identically, and what they
// disagree about is whether it can come back.
//
// `Archived` is reversible — a product pulled from the catalog for a season, or
// while its supplier is sorted out. `@transition(([Archived]) => Listed)` on
// `UnarchiveProduct` offers the way back exactly where it exists.
//
// `Discontinued` is not. No command names it as a from-state, so the generated
// lifecycle diagram draws it terminal and no surface offers a way out. A boolean
// could express the exclusion and nothing else; the second state is what carries
// "can this come back", and a command's `@transition` reads it for free.
@schema
type shelfStatus =
  | Listed
  | @retired Archived
  | @retired Discontinued

// A product that leaves the shelf keeps its name. An order names the products it
// bought, and a shopper reading their own order is holding a pointer the platform
// gave them — archiving the product should not turn that into a bare id. The
// annotation opens one door and only for what a reference needs: id, name, and
// the shelf state the row is in. The catalog list itself stays closed.
@schema
@namedWhenRetired
type state = {
  productId: string,
  name: string,
  description: string,
  price: Reventless.Money.t,
  productImage?: Reventless.UploadableImage.t,
  // Indexed so the server can answer "the products in this category" — a
  // `categoryIdEq` filter on the connection, rather than a client narrowing one
  // loaded page.
  @index categoryId: string,
  // `@lifecycle` makes this the field commands' `@transition`s are written in
  // terms of; the retirements are on the constructors above.
  @lifecycle shelfStatus: shelfStatus,
}
