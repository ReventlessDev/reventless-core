@@reventless.gwt

let cid = CustomerId.make
let oid = OrderId.make
let pid = CatalogSpec.ProductId.make

describe("PlaceOrder StateChangeSlice", () => {
  test("requires referenced products to be synced first", () =>
    givenEvents([])
    ->whenCmd(PlaceOrder({orderId: oid("o1"), customerId: cid("c1"), productIds: [pid("p1")]}))
    ->thenError(ProductsNotAvailable({missing: [pid("p1")]}))
  )

  test("placement succeeds when products are available", () =>
    givenEvents([CatalogProductSynced({productId: pid("p1")})])
    ->whenCmd(PlaceOrder({orderId: oid("o1"), customerId: cid("c1"), productIds: [pid("p1")]}))
    ->thenEvent(OrderPlaced({orderId: oid("o1"), customerId: cid("c1"), productIds: [pid("p1")]}))
  )

  test("partial product availability returns ProductsNotAvailable with missing list", () =>
    givenEvents([CatalogProductSynced({productId: pid("p1")})])
    ->whenCmd(
      PlaceOrder({orderId: oid("o1"), customerId: cid("c1"), productIds: [pid("p1"), pid("p2")]}),
    )
    ->thenError(ProductsNotAvailable({missing: [pid("p2")]}))
  )

  test("re-placing the same orderId returns OrderAlreadyPlaced", () =>
    givenEvents([CatalogProductSynced({productId: pid("p1")}), OrderPlaced({orderId: oid("o1")})])
    ->whenCmd(PlaceOrder({orderId: oid("o1"), customerId: cid("c1"), productIds: [pid("p1")]}))
    ->thenError(OrderAlreadyPlaced)
  )

  test("a sibling OrderPlaced for a different orderId does not block placement", () =>
    givenEvents([CatalogProductSynced({productId: pid("p1")}), OrderPlaced({orderId: oid("o2")})])
    ->whenCmd(PlaceOrder({orderId: oid("o1"), customerId: cid("c1"), productIds: [pid("p1")]}))
    ->thenEvent(OrderPlaced({orderId: oid("o1"), customerId: cid("c1"), productIds: [pid("p1")]}))
  )
})
