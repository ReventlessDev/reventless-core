@@reventless.gwt

// Prices are money, so a test writes the amount a person would say and converts
// it once. `ofMajor` scales by the currency's own exponent, which is what keeps
// the literal honest: 9.99 EUR is 999 cents, and the same call on a JPY price
// would scale by 1.
let eur = amount => Reventless.Money.ofMajor(~amount, ~currency=EUR)

// Written out as literals rather than through a row helper: the lifecycle check
// harvests `shelfStatus` from the sidecar the PPX writes, and it can only read
// what is spelled out.
describe("Products StateViewSliceStream", () => {
  test("ProductAdded creates a row with an empty set", () =>
    givenEvents([])
    ->whenEvent(
      ProductAdded({productId: "p1", name: "Laptop", description: "x", price: eur(999.99), categoryId: "cat1"}),
    )
    ->thenStateWithId(
      "p1",
      {productId: "p1", name: "Laptop", description: "x", price: eur(999.99), productImages: [], categoryId: "cat1", shelfStatus: Listed},
    )
  )

  test("ProductNameChanged updates the name", () =>
    givenEvents([
      ProductAdded({productId: "p1", name: "Laptop", description: "x", price: eur(999.99), categoryId: "cat1"}),
    ])
    ->whenEvent(ProductNameChanged({productId: "p1", name: "Gaming Laptop"}))
    ->thenStateWithId(
      "p1",
      {productId: "p1", name: "Gaming Laptop", description: "x", price: eur(999.99), productImages: [], categoryId: "cat1", shelfStatus: Listed},
    )
  )

  test("ProductDescriptionChanged updates the description", () =>
    givenEvents([
      ProductAdded({productId: "p1", name: "Laptop", description: "x", price: eur(999.99), categoryId: "cat1"}),
    ])
    ->whenEvent(ProductDescriptionChanged({productId: "p1", description: "high-end"}))
    ->thenStateWithId(
      "p1",
      {productId: "p1", name: "Laptop", description: "high-end", price: eur(999.99), productImages: [], categoryId: "cat1", shelfStatus: Listed},
    )
  )

  test("ProductPriceChanged updates the price", () =>
    givenEvents([
      ProductAdded({productId: "p1", name: "Laptop", description: "x", price: eur(999.99), categoryId: "cat1"}),
    ])
    ->whenEvent(ProductPriceChanged({productId: "p1", price: eur(899.99)}))
    ->thenStateWithId(
      "p1",
      {productId: "p1", name: "Laptop", description: "x", price: eur(899.99), productImages: [], categoryId: "cat1", shelfStatus: Listed},
    )
  )

  // The first attachment is the primary until one is chosen, so a card never
  // shows no image while the set has one. Being first IS being the primary —
  // there is no second field to say so, and none to fall out of step.
  test("the first ProductImageAttached becomes the primary", () =>
    givenEvents([
      ProductAdded({productId: "p1", name: "Laptop", description: "x", price: eur(999.99), categoryId: "cat1"}),
    ])
    ->whenEvent(
      ProductImageAttached({productId: "p1", productImage: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg", altText: "front"}),
    )
    ->thenStateWithId(
      "p1",
      {
        productId: "p1",
        name: "Laptop",
        description: "x",
        price: eur(999.99),
        // The caption arrives inside the member, which is where a cell renderer
        // can reach it — it used to sit in a sibling field no cell is handed.
        productImages: [{ref: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg", altText: "front"}],
        categoryId: "cat1",
        shelfStatus: Listed,
      },
    )
  )

  test("a second attachment extends the set and leaves the primary first", () =>
    givenEvents([
      ProductAdded({productId: "p1", name: "Laptop", description: "x", price: eur(999.99), categoryId: "cat1"}),
      ProductImageAttached({productId: "p1", productImage: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg"}),
    ])
    ->whenEvent(
      ProductImageAttached({productId: "p1", productImage: "/uploads/9c1f2a30-0b7e-4a11-9d33-6f0d2e5a8b41/p1-side.jpg"}),
    )
    ->thenStateWithId(
      "p1",
      {
        productId: "p1",
        name: "Laptop",
        description: "x",
        price: eur(999.99),
        productImages: [
          {ref: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg"},
          {ref: "/uploads/9c1f2a30-0b7e-4a11-9d33-6f0d2e5a8b41/p1-side.jpg"},
        ],
        categoryId: "cat1",
        shelfStatus: Listed,
      },
    )
  )

  // What "choose the primary" is on the view: the chosen member moves to the
  // front. This is the assertion that changed shape — the set is now ordered,
  // and attachment order is no longer readable off the row.
  test("ProductPrimaryImageSet moves the chosen member to the front", () =>
    givenEvents([
      ProductAdded({productId: "p1", name: "Laptop", description: "x", price: eur(999.99), categoryId: "cat1"}),
      ProductImageAttached({productId: "p1", productImage: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg"}),
      ProductImageAttached({productId: "p1", productImage: "/uploads/9c1f2a30-0b7e-4a11-9d33-6f0d2e5a8b41/p1-side.jpg"}),
    ])
    ->whenEvent(
      ProductPrimaryImageSet({productId: "p1", productImage: "/uploads/9c1f2a30-0b7e-4a11-9d33-6f0d2e5a8b41/p1-side.jpg"}),
    )
    ->thenStateWithId(
      "p1",
      {
        productId: "p1",
        name: "Laptop",
        description: "x",
        price: eur(999.99),
        productImages: [
          {ref: "/uploads/9c1f2a30-0b7e-4a11-9d33-6f0d2e5a8b41/p1-side.jpg"},
          {ref: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg"},
        ],
        categoryId: "cat1",
        shelfStatus: Listed,
      },
    )
  )

  // No arm says so: removing the head leaves the next member at the head, which
  // is the whole of "the chosen one, else the first attached" on this shape.
  test("removing the primary promotes the next member", () =>
    givenEvents([
      ProductAdded({productId: "p1", name: "Laptop", description: "x", price: eur(999.99), categoryId: "cat1"}),
      ProductImageAttached({productId: "p1", productImage: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg"}),
      ProductImageAttached({productId: "p1", productImage: "/uploads/9c1f2a30-0b7e-4a11-9d33-6f0d2e5a8b41/p1-side.jpg"}),
      ProductPrimaryImageSet({productId: "p1", productImage: "/uploads/9c1f2a30-0b7e-4a11-9d33-6f0d2e5a8b41/p1-side.jpg"}),
    ])
    ->whenEvent(
      ProductImageRemoved({productId: "p1", productImage: "/uploads/9c1f2a30-0b7e-4a11-9d33-6f0d2e5a8b41/p1-side.jpg"}),
    )
    ->thenStateWithId(
      "p1",
      {
        productId: "p1",
        name: "Laptop",
        description: "x",
        price: eur(999.99),
        productImages: [{ref: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg"}],
        categoryId: "cat1",
        shelfStatus: Listed,
      },
    )
  )

  test("removing the last attachment leaves no primary", () =>
    givenEvents([
      ProductAdded({productId: "p1", name: "Laptop", description: "x", price: eur(999.99), categoryId: "cat1"}),
      ProductImageAttached({productId: "p1", productImage: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg"}),
    ])
    ->whenEvent(
      ProductImageRemoved({productId: "p1", productImage: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg"}),
    )
    ->thenStateWithId(
      "p1",
      {productId: "p1", name: "Laptop", description: "x", price: eur(999.99), productImages: [], categoryId: "cat1", shelfStatus: Listed},
    )
  )

  test("ProductImageAltTextSet captions one member", () =>
    givenEvents([
      ProductAdded({productId: "p1", name: "Laptop", description: "x", price: eur(999.99), categoryId: "cat1"}),
      ProductImageAttached({productId: "p1", productImage: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg"}),
    ])
    ->whenEvent(
      ProductImageAltTextSet({productId: "p1", productImage: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg", altText: "front view"}),
    )
    ->thenStateWithId(
      "p1",
      {
        productId: "p1",
        name: "Laptop",
        description: "x",
        price: eur(999.99),
        productImages: [{ref: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg", altText: "front view"}],
        categoryId: "cat1",
        shelfStatus: Listed,
      },
    )
  )

  // Captioning is not choosing: the member is rewritten where it stands, so the
  // primary is whatever it already was.
  test("captioning a non-primary member leaves the order alone", () =>
    givenEvents([
      ProductAdded({productId: "p1", name: "Laptop", description: "x", price: eur(999.99), categoryId: "cat1"}),
      ProductImageAttached({productId: "p1", productImage: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg"}),
      ProductImageAttached({productId: "p1", productImage: "/uploads/9c1f2a30-0b7e-4a11-9d33-6f0d2e5a8b41/p1-side.jpg"}),
    ])
    ->whenEvent(
      ProductImageAltTextSet({productId: "p1", productImage: "/uploads/9c1f2a30-0b7e-4a11-9d33-6f0d2e5a8b41/p1-side.jpg", altText: "side view"}),
    )
    ->thenStateWithId(
      "p1",
      {
        productId: "p1",
        name: "Laptop",
        description: "x",
        price: eur(999.99),
        productImages: [
          {ref: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg"},
          {ref: "/uploads/9c1f2a30-0b7e-4a11-9d33-6f0d2e5a8b41/p1-side.jpg", altText: "side view"},
        ],
        categoryId: "cat1",
        shelfStatus: Listed,
      },
    )
  )

  // The three events that move the shelf, and the reason they are worth a
  // scenario each: `shelfStatus` is the field every declared edge in this plugin
  // is written in terms of, so it is the view — not the slices — that says what
  // "archived" means. A slice claiming it may run on an archived product is
  // claiming something about a row only this fold produces.
  //
  // The row survives all three. An order still references a withdrawn product,
  // and a merchandiser still has to find it; which callers see it afterwards is
  // the resolvers' answer, not this projection's.
  test("ProductArchived moves the product off the shelf", () =>
    givenEvents([
      ProductAdded({productId: "p1", name: "Laptop", description: "x", price: eur(999.99), categoryId: "cat1"}),
    ])
    ->whenEvent(ProductArchived({productId: "p1"}))
    ->thenStateWithId(
      "p1",
      {productId: "p1", name: "Laptop", description: "x", price: eur(999.99), productImages: [], categoryId: "cat1", shelfStatus: Archived},
    )
  )

  test("ProductUnarchived puts it back on the shelf", () =>
    givenEvents([
      ProductAdded({productId: "p1", name: "Laptop", description: "x", price: eur(999.99), categoryId: "cat1"}),
      ProductArchived({productId: "p1"}),
    ])
    ->whenEvent(ProductUnarchived({productId: "p1"}))
    ->thenStateWithId(
      "p1",
      {productId: "p1", name: "Laptop", description: "x", price: eur(999.99), productImages: [], categoryId: "cat1", shelfStatus: Listed},
    )
  )

  test("ProductDiscontinued is the end of the line", () =>
    givenEvents([
      ProductAdded({productId: "p1", name: "Laptop", description: "x", price: eur(999.99), categoryId: "cat1"}),
    ])
    ->whenEvent(ProductDiscontinued({productId: "p1"}))
    ->thenStateWithId(
      "p1",
      {productId: "p1", name: "Laptop", description: "x", price: eur(999.99), productImages: [], categoryId: "cat1", shelfStatus: Discontinued},
    )
  )
})
