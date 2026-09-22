// Multi-source ReadModel: separate `_GWT` instances per source mapping.
// `MultiSourceProjection_GWT.Make` is single-source; spec-stem uniqueness keeps
// the file name singular while we instantiate one functor per mapping.

module ProductGwt = ReventlessGwt.MultiSourceProjection_GWT.Make(
  ProductDemands_Projections.ProductMapping,
)
module ProductDemandGwt = ReventlessGwt.MultiSourceProjection_GWT.Make(
  ProductDemands_Projections.ProductDemandMapping,
)

ProductGwt.describe("ProductDemands ReadModel ← Product", () => {
  // scenario-id: 5a99d971-c604-4533-924a-e3a36cd74364
  ProductGwt.test("Added initialises the entry with orderCount = 0", () =>
    ProductGwt.givenEvents([])
    ->ProductGwt.whenEvent(
      Product.Added({
        name: "Laptop",
        description: "x",
        price: 1.0,
        imageUrl: "/productImages/laptop.jpg",
      }),
    )
    ->ProductGwt.thenState({ProductDemands.name: "Laptop", orderCount: 0})
  )

  // scenario-id: 53a43536-a02d-4c2f-85dd-e9e038f940d9
  ProductGwt.test("NameUpdated is ignored (handled by Products read model)", () =>
    ProductGwt.givenEvents([
      Product.Added({
        name: "Laptop",
        description: "x",
        price: 1.0,
        imageUrl: "/productImages/laptop.jpg",
      }),
    ])
    ->ProductGwt.whenEvent(Product.NameUpdated({name: "Gaming Laptop"}))
    ->ProductGwt.thenState({ProductDemands.name: "Laptop", orderCount: 0})
  )

  // scenario-id: 922cbf7d-ef67-4777-86cb-2dc35883494b
  ProductGwt.test("DescriptionUpdated is ignored", () =>
    ProductGwt.givenEvents([
      Product.Added({
        name: "Laptop",
        description: "x",
        price: 1.0,
        imageUrl: "/productImages/laptop.jpg",
      }),
    ])
    ->ProductGwt.whenEvent(Product.DescriptionUpdated({description: "y"}))
    ->ProductGwt.thenState({ProductDemands.name: "Laptop", orderCount: 0})
  )

  // scenario-id: e563ab45-3036-4d29-a3a3-983ee55457cc
  ProductGwt.test("PriceUpdated is ignored", () =>
    ProductGwt.givenEvents([
      Product.Added({
        name: "Laptop",
        description: "x",
        price: 1.0,
        imageUrl: "/productImages/laptop.jpg",
      }),
    ])
    ->ProductGwt.whenEvent(Product.PriceUpdated({price: 2.0}))
    ->ProductGwt.thenState({ProductDemands.name: "Laptop", orderCount: 0})
  )
})

// `MultiSourceProjection_GWT` is single-source: the ProductDemand mapping
// emits `Update(...)` that needs initial state seeded by the Product
// mapping's `Set(...)`. Tested in isolation, both Update branches surface
// a `StaleState` error. We assert the throw to lock in that the mapping
// never tries to initialise its own row — the integration relies on
// Product.Added arriving first.
ProductDemandGwt.describe("ProductDemands ReadModel ← ProductDemand", () => {
  // scenario-id: d2ac1c9a-efeb-4875-b743-63b4e43c4c54
  ProductDemandGwt.test("Recorded without prior Product.Added throws StaleState", () =>
    ProductDemandGwt.givenEvents([])
    ->ProductDemandGwt.whenEvent(ProductDemand.Recorded({orderId: "order-1"}))
    ->ProductDemandGwt.thenThrow
  )

  // scenario-id: 2b784d7b-910e-401a-9464-485de6fe3e79
  ProductDemandGwt.test("Revoked without prior Product.Added throws StaleState", () =>
    ProductDemandGwt.givenEvents([])
    ->ProductDemandGwt.whenEvent(ProductDemand.Revoked({orderId: "order-1"}))
    ->ProductDemandGwt.thenThrow
  )
})
