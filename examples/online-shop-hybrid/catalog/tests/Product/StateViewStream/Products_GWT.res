@@reventless.gwt

open CatalogExamples

// Prices are money, so a test writes the amount a person would say and converts
// it once. `ofMajor` scales by the currency's own exponent, which is what keeps
// the literal honest: 9.99 EUR is 999 cents, and the same call on a JPY price
// would scale by 1.

// Written out as literals rather than through a row helper: the lifecycle check
// harvests `shelfStatus` from the sidecar the PPX writes, and it can only read
// what is spelled out.

// Every event a projection GWT feeds carries the harness's fixed producer time,
// so every trail entry below is stamped with that one instant.
let trail = (states: array<shelfStatus>) =>
  states->Array.map((state): Reventless.Lifecycle.Trail.entry<shelfStatus> => {
    state,
    at: "1970-01-01T00:00:00Z",
  })

describe("Products StateViewSliceStream", () => {
  // scenario-id: 5a7dc3aa-3806-4b78-b84d-67989c3ba21c
  test("ProductAdded creates a row with an empty set", () =>
    givenEvents([])
    ->whenEvent(
      ProductAdded({
        productId: p1,
        name: laptop,
        description: anyDescription,
        price: laptopPrice,
        categoryId: cat1,
      }),
    )
    ->thenStateWithId(
      "p1",
      {
        productId: p1,
        name: laptop,
        description: anyDescription,
        price: laptopPrice,
        productImages: [],
        categoryId: cat1,
        shelfStatus: Listed,
        trail: trail([Listed]),
      },
    )
  )

  // scenario-id: 965fb413-cb37-4fe6-8ba5-f6ee1b57270b
  test("ProductNameChanged updates the name", () =>
    givenEvents([
      ProductAdded({
        productId: p1,
        name: laptop,
        description: anyDescription,
        price: laptopPrice,
        categoryId: cat1,
      }),
    ])
    ->whenEvent(ProductNameChanged({productId: p1, name: gamingLaptop}))
    ->thenStateWithId(
      "p1",
      {
        productId: p1,
        name: gamingLaptop,
        description: anyDescription,
        price: laptopPrice,
        productImages: [],
        categoryId: cat1,
        shelfStatus: Listed,
        trail: trail([Listed]),
      },
    )
  )

  // scenario-id: f0cd94f8-f938-43d2-b05c-6c0cf2cff2a6
  test("ProductDescriptionChanged updates the description", () =>
    givenEvents([
      ProductAdded({
        productId: p1,
        name: laptop,
        description: anyDescription,
        price: laptopPrice,
        categoryId: cat1,
      }),
    ])
    ->whenEvent(ProductDescriptionChanged({productId: p1, description: highEnd}))
    ->thenStateWithId(
      "p1",
      {
        productId: p1,
        name: laptop,
        description: highEnd,
        price: laptopPrice,
        productImages: [],
        categoryId: cat1,
        shelfStatus: Listed,
        trail: trail([Listed]),
      },
    )
  )

  // scenario-id: 7b1245dd-6832-428e-a3a4-3e3f40d18d07
  test("ProductPriceChanged updates the price", () =>
    givenEvents([
      ProductAdded({
        productId: p1,
        name: laptop,
        description: anyDescription,
        price: laptopPrice,
        categoryId: cat1,
      }),
    ])
    ->whenEvent(ProductPriceChanged({productId: p1, price: laptopChangedPrice}))
    ->thenStateWithId(
      "p1",
      {
        productId: p1,
        name: laptop,
        description: anyDescription,
        price: laptopChangedPrice,
        productImages: [],
        categoryId: cat1,
        shelfStatus: Listed,
        trail: trail([Listed]),
      },
    )
  )

  // The first attachment is the primary until one is chosen, so a card never
  // shows no image while the set has one. Being first IS being the primary —
  // there is no second field to say so, and none to fall out of step.
  // scenario-id: 7b0abb07-cc95-41c6-a01f-db55944a12a6
  test("the first ProductImageAttached becomes the primary", () =>
    givenEvents([
      ProductAdded({
        productId: p1,
        name: laptop,
        description: anyDescription,
        price: laptopPrice,
        categoryId: cat1,
      }),
    ])
    ->whenEvent(
      ProductImageAttached({
        productId: p1,
        productImage: frontImage,
        altText: frontAlt,
      }),
    )
    ->thenStateWithId(
      "p1",
      {
        productId: p1,
        name: laptop,
        description: anyDescription,
        price: laptopPrice,
        // The caption arrives inside the member, which is where a cell renderer
        // can reach it — it used to sit in a sibling field no cell is handed.
        productImages: [
          {ref: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg", altText: "front"},
        ],
        categoryId: cat1,
        shelfStatus: Listed,
        trail: trail([Listed]),
      },
    )
  )

  // scenario-id: 312dab96-9a11-4a64-abf1-1492c1f1d030
  test("a second attachment extends the set and leaves the primary first", () =>
    givenEvents([
      ProductAdded({
        productId: p1,
        name: laptop,
        description: anyDescription,
        price: laptopPrice,
        categoryId: cat1,
      }),
      ProductImageAttached({
        productId: p1,
        productImage: frontImage,
      }),
    ])
    ->whenEvent(
      ProductImageAttached({
        productId: p1,
        productImage: sideImage,
      }),
    )
    ->thenStateWithId(
      "p1",
      {
        productId: p1,
        name: laptop,
        description: anyDescription,
        price: laptopPrice,
        productImages: [
          {ref: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg"},
          {ref: "/uploads/9c1f2a30-0b7e-4a11-9d33-6f0d2e5a8b41/p1-side.jpg"},
        ],
        categoryId: cat1,
        shelfStatus: Listed,
        trail: trail([Listed]),
      },
    )
  )

  // What "choose the primary" is on the view: the chosen member moves to the
  // front. This is the assertion that changed shape — the set is now ordered,
  // and attachment order is no longer readable off the row.
  // scenario-id: 62198d48-1176-4821-96dd-86d7db10faa7
  test("ProductPrimaryImageSet moves the chosen member to the front", () =>
    givenEvents([
      ProductAdded({
        productId: p1,
        name: laptop,
        description: anyDescription,
        price: laptopPrice,
        categoryId: cat1,
      }),
      ProductImageAttached({
        productId: p1,
        productImage: frontImage,
      }),
      ProductImageAttached({
        productId: p1,
        productImage: sideImage,
      }),
    ])
    ->whenEvent(
      ProductPrimaryImageSet({
        productId: p1,
        productImage: sideImage,
      }),
    )
    ->thenStateWithId(
      "p1",
      {
        productId: p1,
        name: laptop,
        description: anyDescription,
        price: laptopPrice,
        productImages: [
          {ref: "/uploads/9c1f2a30-0b7e-4a11-9d33-6f0d2e5a8b41/p1-side.jpg"},
          {ref: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg"},
        ],
        categoryId: cat1,
        shelfStatus: Listed,
        trail: trail([Listed]),
      },
    )
  )

  // No arm says so: removing the head leaves the next member at the head, which
  // is the whole of "the chosen one, else the first attached" on this shape.
  // scenario-id: 7bb74bae-2118-495d-992c-4a014129a5e1
  test("removing the primary promotes the next member", () =>
    givenEvents([
      ProductAdded({
        productId: p1,
        name: laptop,
        description: anyDescription,
        price: laptopPrice,
        categoryId: cat1,
      }),
      ProductImageAttached({
        productId: p1,
        productImage: frontImage,
      }),
      ProductImageAttached({
        productId: p1,
        productImage: sideImage,
      }),
      ProductPrimaryImageSet({
        productId: p1,
        productImage: sideImage,
      }),
    ])
    ->whenEvent(
      ProductImageRemoved({
        productId: p1,
        productImage: sideImage,
      }),
    )
    ->thenStateWithId(
      "p1",
      {
        productId: p1,
        name: laptop,
        description: anyDescription,
        price: laptopPrice,
        productImages: [{ref: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg"}],
        categoryId: cat1,
        shelfStatus: Listed,
        trail: trail([Listed]),
      },
    )
  )

  // scenario-id: 07dbc718-1a03-402a-a073-e9561933d4ce
  test("removing the last attachment leaves no primary", () =>
    givenEvents([
      ProductAdded({
        productId: p1,
        name: laptop,
        description: anyDescription,
        price: laptopPrice,
        categoryId: cat1,
      }),
      ProductImageAttached({
        productId: p1,
        productImage: frontImage,
      }),
    ])
    ->whenEvent(
      ProductImageRemoved({
        productId: p1,
        productImage: frontImage,
      }),
    )
    ->thenStateWithId(
      "p1",
      {
        productId: p1,
        name: laptop,
        description: anyDescription,
        price: laptopPrice,
        productImages: [],
        categoryId: cat1,
        shelfStatus: Listed,
        trail: trail([Listed]),
      },
    )
  )

  // scenario-id: 3eb123d9-6d30-4e45-8ac0-8db4070684ef
  test("ProductImageAltTextSet captions one member", () =>
    givenEvents([
      ProductAdded({
        productId: p1,
        name: laptop,
        description: anyDescription,
        price: laptopPrice,
        categoryId: cat1,
      }),
      ProductImageAttached({
        productId: p1,
        productImage: frontImage,
      }),
    ])
    ->whenEvent(
      ProductImageAltTextSet({
        productId: p1,
        productImage: frontImage,
        altText: "front view",
      }),
    )
    ->thenStateWithId(
      "p1",
      {
        productId: p1,
        name: laptop,
        description: anyDescription,
        price: laptopPrice,
        productImages: [
          {ref: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg", altText: "front view"},
        ],
        categoryId: cat1,
        shelfStatus: Listed,
        trail: trail([Listed]),
      },
    )
  )

  // Captioning is not choosing: the member is rewritten where it stands, so the
  // primary is whatever it already was.
  // scenario-id: fead3d6c-17b6-4aa1-b0d9-acf6651d9640
  test("captioning a non-primary member leaves the order alone", () =>
    givenEvents([
      ProductAdded({
        productId: p1,
        name: laptop,
        description: anyDescription,
        price: laptopPrice,
        categoryId: cat1,
      }),
      ProductImageAttached({
        productId: p1,
        productImage: frontImage,
      }),
      ProductImageAttached({
        productId: p1,
        productImage: sideImage,
      }),
    ])
    ->whenEvent(
      ProductImageAltTextSet({
        productId: p1,
        productImage: sideImage,
        altText: "side view",
      }),
    )
    ->thenStateWithId(
      "p1",
      {
        productId: p1,
        name: laptop,
        description: anyDescription,
        price: laptopPrice,
        productImages: [
          {ref: "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg"},
          {ref: "/uploads/9c1f2a30-0b7e-4a11-9d33-6f0d2e5a8b41/p1-side.jpg", altText: "side view"},
        ],
        categoryId: cat1,
        shelfStatus: Listed,
        trail: trail([Listed]),
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
  // scenario-id: 4f9707f8-1e3b-4817-97b5-664d5c0fcf6a
  test("ProductArchived moves the product off the shelf", () =>
    givenEvents([
      ProductAdded({
        productId: p1,
        name: laptop,
        description: anyDescription,
        price: laptopPrice,
        categoryId: cat1,
      }),
    ])
    ->whenEvent(ProductArchived({productId: p1}))
    ->thenStateWithId(
      "p1",
      {
        productId: p1,
        name: laptop,
        description: anyDescription,
        price: laptopPrice,
        productImages: [],
        categoryId: cat1,
        shelfStatus: Archived,
        trail: trail([Listed, Archived]),
      },
    )
  )

  // scenario-id: 7c467c17-b26a-4793-afd0-89cc0b6d010a
  test("ProductUnarchived puts it back on the shelf", () =>
    givenEvents([
      ProductAdded({
        productId: p1,
        name: laptop,
        description: anyDescription,
        price: laptopPrice,
        categoryId: cat1,
      }),
      ProductArchived({productId: p1}),
    ])
    ->whenEvent(ProductUnarchived({productId: p1}))
    ->thenStateWithId(
      "p1",
      {
        productId: p1,
        name: laptop,
        description: anyDescription,
        price: laptopPrice,
        productImages: [],
        categoryId: cat1,
        shelfStatus: Listed,
        trail: trail([Listed, Archived, Listed]),
      },
    )
  )

  // scenario-id: 84b6af02-b5f6-4fd3-8fb4-4349f1c3f4e5
  test("ProductDiscontinued is the end of the line", () =>
    givenEvents([
      ProductAdded({
        productId: p1,
        name: laptop,
        description: anyDescription,
        price: laptopPrice,
        categoryId: cat1,
      }),
    ])
    ->whenEvent(ProductDiscontinued({productId: p1}))
    ->thenStateWithId(
      "p1",
      {
        productId: p1,
        name: laptop,
        description: anyDescription,
        price: laptopPrice,
        productImages: [],
        categoryId: cat1,
        shelfStatus: Discontinued,
        trail: trail([Listed, Discontinued]),
      },
    )
  )
})
