// Worked examples for Query_GWT — covers both a ReadModel and a StateViewSlice
// to prove the unified DSL works for either consumer type. Stage 6 of
// `docs/plans/reventless-gwt.md`.

S.enableJson()

// ---------------------------------------------------------------------------
// Case 1 — ReadModel: Categories.
// ---------------------------------------------------------------------------

module CategoriesReadModel = {
  module Id = Reventless.Id.StringPure
  let name = "Categories"
  let moduleUrl = ""

  @schema
  type state = {categoryId: string, name: string, archived: bool}

  let config = Reventless.ReadModel.config(
    ~indexes=[
      {
        index: "byName",
        type_: "S",
        idField: "name",
        projectionType: ALL,
      },
    ],
  )
  let subIdConfig = None
}

module CategoriesQuery = Query_GWT.Make(Query_GWT.FromReadModel(CategoriesReadModel))

CategoriesQuery.describe("Categories ReadModel queries", () => {
  CategoriesQuery.test("primary-id lookup returns the row", () =>
    CategoriesQuery.givenStore([
      ("c1", {categoryId: "c1", name: "Electronics", archived: false}),
      ("c2", {categoryId: "c2", name: "Books", archived: true}),
    ])
    ->CategoriesQuery.whenQueryById("c1")
    ->CategoriesQuery.thenRow(Some({categoryId: "c1", name: "Electronics", archived: false}))
  )

  CategoriesQuery.test("by-name (GSI) returns matching rows", () =>
    CategoriesQuery.givenStore([
      ("c1", {categoryId: "c1", name: "Electronics", archived: false}),
      ("c2", {categoryId: "c2", name: "Books", archived: true}),
    ])
    ->CategoriesQuery.whenQuery({by: "name", value: "Electronics", index: "byName"})
    ->CategoriesQuery.thenRows([{categoryId: "c1", name: "Electronics", archived: false}])
  )

  CategoriesQuery.test("missing index produces QueryRowsMismatch", () => {
    let outcome =
      CategoriesQuery.givenStore([
        ("c1", {categoryId: "c1", name: "Electronics", archived: false}),
      ])
      ->CategoriesQuery.whenQuery({by: "name", value: "Electronics", index: "byArchived"})
      ->CategoriesQuery.thenRows([])
    switch outcome {
    | Error(QueryRowsMismatch(_)) => Outcome.pass
    | Error(other) =>
      Outcome.fail(
        Throw({error: "expected QueryRowsMismatch, got: " ++ Outcome.kindName(other), stack: ""}),
      )
    | Ok() => Outcome.fail(Throw({error: "expected failure, got pass", stack: ""}))
    }
  })

  CategoriesQuery.test("filter narrows results after the index scan", () =>
    CategoriesQuery.givenStore([
      ("c1", {categoryId: "c1", name: "Books", archived: false}),
      ("c2", {categoryId: "c2", name: "Books", archived: true}),
    ])
    ->CategoriesQuery.whenQuery({
      by: "name",
      value: "Books",
      index: "byName",
      filter: r => !r.archived,
    })
    ->CategoriesQuery.thenRows([{categoryId: "c1", name: "Books", archived: false}])
  )

  CategoriesQuery.test("limit truncates results and thenRowCount verifies", () =>
    CategoriesQuery.givenStore(
      Array.fromInitializer(~length=10, i => {
        let id = "c" ++ i->Int.toString
        let state: CategoriesReadModel.state = {categoryId: id, name: "Books", archived: false}
        (id, state)
      }),
    )
    ->CategoriesQuery.whenQuery({by: "name", value: "Books", index: "byName", limit: 3})
    ->CategoriesQuery.thenRowCount(3)
  )

  CategoriesQuery.test("composite-id lookup without subIdConfig fails", () => {
    let outcome =
      CategoriesQuery.givenStore([])
      ->CategoriesQuery.whenQueryByCompositeId({id: "c1", subId: "v1"})
      ->CategoriesQuery.thenRowFromComposite(None)
    switch outcome {
    | Error(QueryRowsMismatch(_)) => Outcome.pass
    | Error(other) =>
      Outcome.fail(
        Throw({error: "expected QueryRowsMismatch, got: " ++ Outcome.kindName(other), stack: ""}),
      )
    | Ok() => Outcome.fail(Throw({error: "expected failure, got pass", stack: ""}))
    }
  })
})

// ---------------------------------------------------------------------------
// Case 2 — StateViewSlice: Orders-by-customer, composite key (id=orderId, subId=customerId).
// ---------------------------------------------------------------------------

module OrdersView = {
  let name = "OrdersView"
  let moduleUrl = ""

  @schema
  type state = {orderId: string, customerId: string, total: int}

  @schema
  type consumedEvent = OrderPlaced({orderId: string, customerId: string, total: int})

  let project = ({event}: Reventless.StateViewSlice.consumed<consumedEvent>) =>
    switch event {
    | OrderPlaced({orderId, customerId, total}) => [
        Reventless.Projection.Set(orderId, {orderId, customerId, total}),
      ]
    }

  let config = Reventless.ReadModel.config()
  let subIdConfig = Some({
    Reventless.ReadModel.subIdField: "customerId",
    getSubId: (s: state) => s.customerId,
  })
}

module OrdersQuery = Query_GWT.Make(Query_GWT.FromStateViewSlice(OrdersView))

OrdersQuery.describe("OrdersView StateViewSlice queries", () => {
  OrdersQuery.test("composite-id lookup returns the row", () =>
    OrdersQuery.givenCompositeStore([
      ("ord-1", "cust-a", {orderId: "ord-1", customerId: "cust-a", total: 100}),
      ("ord-2", "cust-b", {orderId: "ord-2", customerId: "cust-b", total: 200}),
    ])
    ->OrdersQuery.whenQueryByCompositeId({id: "ord-1", subId: "cust-a"})
    ->OrdersQuery.thenRowFromComposite(
      Some({orderId: "ord-1", customerId: "cust-a", total: 100}),
    )
  )

  OrdersQuery.test("composite-id lookup with wrong subId returns None", () =>
    OrdersQuery.givenCompositeStore([
      ("ord-1", "cust-a", {orderId: "ord-1", customerId: "cust-a", total: 100}),
    ])
    ->OrdersQuery.whenQueryByCompositeId({id: "ord-1", subId: "cust-z"})
    ->OrdersQuery.thenRowFromComposite(None)
  )
})
