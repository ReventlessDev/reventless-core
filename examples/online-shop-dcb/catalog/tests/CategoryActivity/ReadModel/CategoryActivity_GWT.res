// Multi-source ReadModel: one `_GWT` instance per source mapping. The
// `MultiSourceProjection_GWT.Make` functor is single-source — wire one GWT
// module per Source view and let each describe its own slice of behaviour.

module CategoryGwt = ReventlessGwt.MultiSourceProjection_GWT.Make(
  CategoryActivity_Projections.CategoryActivityMapping,
)
module ProductGwt = ReventlessGwt.MultiSourceProjection_GWT.Make(
  CategoryActivity_Projections.ProductActivityMapping,
)

CategoryGwt.describe("CategoryActivity ReadModel ← Category DCB events", () => {
  CategoryGwt.test("CategoryAdded sets name + kind=Category lastChange=Added", () =>
    CategoryGwt.givenEvents([])
    ->CategoryGwt.whenEvent(
      CategoryActivity_Projections.CategoryEvents.CategoryAdded({
        categoryId: "c1",
        name: "Electronics",
      }),
    )
    ->CategoryGwt.thenStateWithId(
      "c1",
      {CategoryActivity.name: "Electronics", kind: Category, lastChange: Added},
    )
  )

  CategoryGwt.test("CategoryRenamed updates name + lastChange=Renamed", () =>
    CategoryGwt.givenEvents([
      CategoryActivity_Projections.CategoryEvents.CategoryAdded({
        categoryId: "c1",
        name: "Electronics",
      }),
    ])
    ->CategoryGwt.whenEvent(
      CategoryActivity_Projections.CategoryEvents.CategoryRenamed({
        categoryId: "c1",
        name: "Consumer Electronics",
      }),
    )
    ->CategoryGwt.thenStateWithId(
      "c1",
      {CategoryActivity.name: "Consumer Electronics", kind: Category, lastChange: Renamed},
    )
  )

  CategoryGwt.test("CategoryArchived keeps name and sets lastChange=Archived", () =>
    CategoryGwt.givenEvents([
      CategoryActivity_Projections.CategoryEvents.CategoryAdded({
        categoryId: "c1",
        name: "Electronics",
      }),
    ])
    ->CategoryGwt.whenEvent(
      CategoryActivity_Projections.CategoryEvents.CategoryArchived({categoryId: "c1"}),
    )
    ->CategoryGwt.thenStateWithId(
      "c1",
      {CategoryActivity.name: "Electronics", kind: Category, lastChange: Archived},
    )
  )
})

ProductGwt.describe("CategoryActivity ReadModel ← Product DCB events", () => {
  ProductGwt.test("ProductAdded sets name + kind=Product lastChange=Added", () =>
    ProductGwt.givenEvents([])
    ->ProductGwt.whenEvent(
      CategoryActivity_Projections.ProductEvents.ProductAdded({
        productId: "p1",
        name: "Laptop",
        description: "x",
        price: 1.0,
      }),
    )
    ->ProductGwt.thenStateWithId(
      "p1",
      {CategoryActivity.name: "Laptop", kind: Product, lastChange: Added},
    )
  )

  ProductGwt.test("ProductNameChanged updates name + lastChange=Renamed", () =>
    ProductGwt.givenEvents([
      CategoryActivity_Projections.ProductEvents.ProductAdded({
        productId: "p1",
        name: "Laptop",
        description: "x",
        price: 1.0,
      }),
    ])
    ->ProductGwt.whenEvent(
      CategoryActivity_Projections.ProductEvents.ProductNameChanged({
        productId: "p1",
        name: "Gaming Laptop",
      }),
    )
    ->ProductGwt.thenStateWithId(
      "p1",
      {CategoryActivity.name: "Gaming Laptop", kind: Product, lastChange: Renamed},
    )
  )
})
