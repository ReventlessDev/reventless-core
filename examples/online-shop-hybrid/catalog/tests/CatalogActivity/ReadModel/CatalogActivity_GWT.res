// Multi-source ReadModel: one `_GWT` instance per source mapping. Same
// reasoning as the aggregates-pattern multi-source ReadModel — the
// `MultiSourceProjection_GWT.Make` functor is single-source.

module CategoryGwt = ReventlessGwt.MultiSourceProjection_GWT.Make(
  CatalogActivity_Projections.CategoryActivityMapping,
)
module ProductGwt = ReventlessGwt.MultiSourceProjection_GWT.Make(
  CatalogActivity_Projections.ProductActivityMapping,
)

CategoryGwt.describe("CatalogActivity ReadModel ← Category Aggregate", () => {
  CategoryGwt.test("Category.Added sets name + kind=Category lastChange=Added", () =>
    CategoryGwt.givenEvents([])
    ->CategoryGwt.whenEvent(Category.Added({name: "Electronics"}))
    ->CategoryGwt.thenState({
      CatalogActivity.name: "Electronics",
      kind: Category,
      lastChange: Added,
    })
  )

  CategoryGwt.test("Category.Renamed updates name + lastChange=Renamed", () =>
    CategoryGwt.givenEvents([Category.Added({name: "Electronics"})])
    ->CategoryGwt.whenEvent(Category.Renamed({name: "Consumer Electronics"}))
    ->CategoryGwt.thenState({
      CatalogActivity.name: "Consumer Electronics",
      kind: Category,
      lastChange: Renamed,
    })
  )

  CategoryGwt.test("Category.Archived keeps name and sets lastChange=Archived", () =>
    CategoryGwt.givenEvents([Category.Added({name: "Electronics"})])
    ->CategoryGwt.whenEvent(Category.Archived)
    ->CategoryGwt.thenState({
      CatalogActivity.name: "Electronics",
      kind: Category,
      lastChange: Archived,
    })
  )
})

ProductGwt.describe("CatalogActivity ReadModel ← Catalog DCB EventLog", () => {
  ProductGwt.test("ProductAdded sets name + kind=Product lastChange=Added", () =>
    ProductGwt.givenEvents([])
    ->ProductGwt.whenEvent(
      CatalogActivity_Projections.CatalogDcbSource.ProductAdded({
        productId: "p1",
        name: "Laptop",
        description: "x",
        price: 1.0,
      }),
    )
    ->ProductGwt.thenStateWithId(
      "p1",
      {CatalogActivity.name: "Laptop", kind: Product, lastChange: Added},
    )
  )

  ProductGwt.test("ProductRenamed updates name + lastChange=Renamed", () =>
    ProductGwt.givenEvents([
      CatalogActivity_Projections.CatalogDcbSource.ProductAdded({
        productId: "p1",
        name: "Laptop",
        description: "x",
        price: 1.0,
      }),
    ])
    ->ProductGwt.whenEvent(
      CatalogActivity_Projections.CatalogDcbSource.ProductRenamed({
        productId: "p1",
        name: "Gaming Laptop",
      }),
    )
    ->ProductGwt.thenStateWithId(
      "p1",
      {CatalogActivity.name: "Gaming Laptop", kind: Product, lastChange: Renamed},
    )
  )
})
