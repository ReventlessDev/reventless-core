// Products StateViewSliceStream.
// Projects product events from the shared catalog event log into a Products read model.

@@reventless.spec

// Order is load-bearing: sury strands constructors declared after a run of two or
// more same-shaped ones, so the `Money.t` pair must lead (DZakh/sury#392).
@schema
type consumedEvent =
  | ProductAdded({
      productId: string,
      name: string,
      description: string,
      price: Reventless.Money.t,
      categoryId: string,
    })
  | ProductPriceChanged({productId: string, price: Reventless.Money.t})
  | ProductNameChanged({productId: string, name: string})
  | ProductDescriptionChanged({productId: string, description: string})
  | ProductImageAttached({
      productId: string,
      productImage: Reventless.UploadableImage.t,
      altText?: string,
    })
  | ProductImageRemoved({productId: string, productImage: Reventless.UploadableImage.t})
  | ProductPrimaryImageSet({productId: string, productImage: Reventless.UploadableImage.t})
  | ProductImageAltTextSet({
      productId: string,
      productImage: Reventless.UploadableImage.t,
      altText: string,
    })
  | ProductArchived({productId: string})
  | ProductUnarchived({productId: string})
  | ProductDiscontinued({productId: string})

// Two ways off the shelf: both withdraw the row identically, and what they
// disagree about is whether it can come back. `Moves([Archived], Listed)` on
// `UnarchiveProduct` offers the way back; nothing names `Discontinued` as a
// from-state, so the generated diagram draws it terminal.
@schema
type shelfStatus =
  | Listed
  | @retired Archived
  | @retired Discontinued

// A product that leaves the shelf keeps its name — an order names the products
// it bought. The annotation opens one door and only for what a reference needs:
// id, name and shelf state. The catalog list itself stays closed.
@schema @namedWhenRetired
type state = {
  productId: string,
  name: string,
  description: string,
  price: Reventless.Money.t,
  // The attachment set, primary first. A card, tile or list cell takes `[0]`;
  // the detail page draws the whole set. The alternative text rides inside each
  // member, where a cell renderer — handed a field and a value, never the row —
  // can reach it. Named for its store, so `productImages` is provisioned.
  productImages: array<Reventless.CaptionedImage.t>,
  // The reference, not a captured name: this view is keyed by `productId`, so a
  // copy could never be refreshed on a category rename. `@index` lets the server
  // answer `categoryIdEq` rather than a client narrowing one loaded page.
  @index @groupBy categoryId: string,
  // `@lifecycle` makes this the field commands' declared edges are written in
  // terms of; the retirements are on the constructors above.
  @lifecycle shelfStatus: shelfStatus,
  // When this product reached each shelf state, appended by the projection
  // machinery. The withdrawals finally have dates; they never had any.
  trail: Reventless.Lifecycle.Trail.t<shelfStatus>,
}
