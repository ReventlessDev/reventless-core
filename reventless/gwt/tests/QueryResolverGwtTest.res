// Worked example for Query_GWT.MakeResolver — cross-spec (`@resolves` /
// `@resolvesMany`) GraphQL resolvers. An Orders read model carries a foreign
// productId (and a productIds array) that resolve into a Products read model;
// the resolver DSL follows those keys across the spec boundary.


module RM = Reventless.ReadModel

module ProductRow = {
  let name = "ProductRow"

  @schema
  type state = {productId: string, name: string, price: float}

  let config = RM.config()
  let subIdConfig = None
}

module OrderRow = {
  let name = "OrderRow"

  @schema
  type state = {orderId: string, productId: string, productIds: array<string>}

  let config = RM.config(
    ~idResolvers=[
      {
        source: {RM.idField: "productId", subId: NoSubId, resolvedField: Single("product")},
        target: {RM.tableName: "ProductRow", idField: Id},
      },
    ],
    ~idsResolvers=[
      {
        source: {RM.idsField: "productIds", resolvedField: "products"},
        target: {RM.tableName: "ProductRow"},
      },
    ],
  )
  let subIdConfig = None
}

module R = Query_GWT.MakeResolver(OrderRow, ProductRow)

let book: ProductRow.state = {productId: "p1", name: "Book", price: 9.99}
let pen: ProductRow.state = {productId: "p2", name: "Pen", price: 1.5}
let order: OrderRow.state = {orderId: "order1", productId: "p1", productIds: ["p1", "p2"]}

let stores = () => R.givenStores([("order1", order)], [("p1", book), ("p2", pen)])

R.describe("Cross-spec resolvers (MakeResolver)", () => {
  R.test("@resolves follows productId into the Products table", () =>
    stores()
    ->R.whenResolve(~field="productId", "order1")
    ->R.thenResolved(Some(book))
  )

  R.test("@resolvesMany follows productIds into multiple Products rows", () =>
    stores()
    ->R.whenResolveMany(~field="productIds", "order1")
    ->R.thenResolvedMany([book, pen])
  )

  R.test("resolving an unknown foreign key returns no row", () =>
    R.givenStores([("order2", {OrderRow.orderId: "order2", productId: "px", productIds: []})], [
      ("p1", book),
    ])
    ->R.whenResolve(~field="productId", "order2")
    ->R.thenResolved(None)
  )
})
