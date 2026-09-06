@@reventless.gwt

describe("PlaceOrder StateChangeSlice", () => {
  test("requires referenced products to be synced first", () =>
    givenEvents([])
    ->whenCmd(
      PlaceOrder({orderId: "o1", customerId: "c1", productIds: ["p1"], shippingMethod: Standard}),
    )
    ->thenError(ProductsNotAvailable({missing: ["p1"]}))
  )

  test("placement succeeds when products are available", () =>
    givenEvents([CatalogProductSynced({productId: "p1", name: "Fathom Dock"})])
    ->whenCmd(
      PlaceOrder({orderId: "o1", customerId: "c1", productIds: ["p1"], shippingMethod: Standard}),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        shippingMethod: Standard,
        firstProductName: "Fathom Dock",
      }),
    )
  )

  test("the chosen shipping method is carried onto the event", () =>
    givenEvents([CatalogProductSynced({productId: "p1", name: "Fathom Dock"})])
    ->whenCmd(
      PlaceOrder({orderId: "o1", customerId: "c1", productIds: ["p1"], shippingMethod: Express}),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        shippingMethod: Express,
        firstProductName: "Fathom Dock",
      }),
    )
  )

  // The requested delivery slot is a single `DateRange`, not a `start*`/`end*`
  // name pair, and it rides the command straight onto the event unchanged. A
  // Standard order can still ask for a window; an order that omits it carries no
  // key at all (the optional field above).
  test("a requested delivery window is carried onto the event", () => {
    let window = Reventless.DateRange.make(
      ~start="2026-03-02T09:00:00Z",
      ~end_="2026-03-02T11:00:00Z",
    )->Result.getOrThrow
    givenEvents([CatalogProductSynced({productId: "p1", name: "Fathom Dock"})])
    ->whenCmd(
      PlaceOrder({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        shippingMethod: Standard,
        deliveryWindow: window,
      }),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        shippingMethod: Standard,
        deliveryWindow: window,
        firstProductName: "Fathom Dock",
      }),
    )
  })

  test("partial product availability returns ProductsNotAvailable with missing list", () =>
    givenEvents([CatalogProductSynced({productId: "p1", name: "Fathom Dock"})])
    ->whenCmd(
      PlaceOrder({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1", "p2"],
        shippingMethod: Standard,
      }),
    )
    ->thenError(ProductsNotAvailable({missing: ["p2"]}))
  )

  // The shelf lifecycle reaching the decision. The view deletes a withdrawn
  // product's row, so a shopper never sees it; these pin the write side to the
  // same answer, which is the half that was missing.
  test("a withdrawn product can no longer be ordered", () =>
    givenEvents([
      CatalogProductSynced({productId: "p1", name: "Fathom Dock"}),
      CatalogProductWithdrawn({productId: "p1"}),
    ])
    ->whenCmd(
      PlaceOrder({orderId: "o1", customerId: "c1", productIds: ["p1"], shippingMethod: Standard}),
    )
    ->thenError(ProductsNotAvailable({missing: ["p1"]}))
  )

  // Withdrawal removes one id, not the shelf.
  test("withdrawing one product leaves its siblings orderable", () =>
    givenEvents([
      CatalogProductSynced({productId: "p1", name: "Fathom Dock"}),
      CatalogProductSynced({productId: "p2", name: "Cirrus Charger"}),
      CatalogProductWithdrawn({productId: "p2"}),
    ])
    ->whenCmd(
      PlaceOrder({orderId: "o1", customerId: "c1", productIds: ["p1"], shippingMethod: Standard}),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        shippingMethod: Standard,
        firstProductName: "Fathom Dock",
      }),
    )
  )

  // A basket that mixes live and withdrawn stock names only what it refused.
  test("a basket naming a withdrawn product reports just that product as missing", () =>
    givenEvents([
      CatalogProductSynced({productId: "p1", name: "Fathom Dock"}),
      CatalogProductSynced({productId: "p2", name: "Cirrus Charger"}),
      CatalogProductWithdrawn({productId: "p2"}),
    ])
    ->whenCmd(
      PlaceOrder({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1", "p2"],
        shippingMethod: Standard,
      }),
    )
    ->thenError(ProductsNotAvailable({missing: ["p2"]}))
  )

  // And the way back. A relist that did not restore orderability would break the
  // lifecycle in the other direction — off the shelf permanently.
  test("a relisted product can be ordered again", () =>
    givenEvents([
      CatalogProductSynced({productId: "p1", name: "Fathom Dock"}),
      CatalogProductWithdrawn({productId: "p1"}),
      CatalogProductRelisted({productId: "p1", name: "Fathom Dock"}),
    ])
    ->whenCmd(
      PlaceOrder({orderId: "o1", customerId: "c1", productIds: ["p1"], shippingMethod: Standard}),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        shippingMethod: Standard,
        firstProductName: "Fathom Dock",
      }),
    )
  )

  // What the order records about what was bought. The name is copied off the
  // shelf as it reads at placement, because an order is a record of a purchase
  // and the catalog goes on changing after it — a rename, a withdrawal. Reading
  // it live would rewrite history every time the shop tidied its shelves.
  test("a rename before placement is captured under the new name", () =>
    givenEvents([
      CatalogProductSynced({productId: "p1", name: "Fathom Dock"}),
      CatalogProductSynced({productId: "p1", name: "Fathom Dock 4-Port"}),
    ])
    ->whenCmd(
      PlaceOrder({orderId: "o1", customerId: "c1", productIds: ["p1"], shippingMethod: Standard}),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        shippingMethod: Standard,
        firstProductName: "Fathom Dock 4-Port",
      }),
    )
  )

  // The FIRST product names the order, and a basket is ordered. Naming the
  // basket after whichever product the fold happened to see last would make the
  // same order read differently depending on catalog traffic.
  test("a basket is named after its first product, not its last", () =>
    givenEvents([
      CatalogProductSynced({productId: "p1", name: "Fathom Dock"}),
      CatalogProductSynced({productId: "p2", name: "Cirrus Charger"}),
    ])
    ->whenCmd(
      PlaceOrder({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p2", "p1"],
        shippingMethod: Standard,
      }),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p2", "p1"],
        shippingMethod: Standard,
        firstProductName: "Cirrus Charger",
      }),
    )
  )

  // The picture travels the same road as the name, and freezes the same way.
  test("the first product's picture is captured onto the event", () =>
    givenEvents([
      CatalogProductSynced({productId: "p1", name: "Fathom Dock"}),
      CatalogProductImageChanged({
        productId: "p1",
        productImage: Reventless.UploadableImage.unsafe("/uploads/Catalog/productImages/a/dock.png"),
      }),
    ])
    ->whenCmd(
      PlaceOrder({orderId: "o1", customerId: "c1", productIds: ["p1"], shippingMethod: Standard}),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        shippingMethod: Standard,
        firstProductName: "Fathom Dock",
        firstProductImage: Reventless.UploadableImage.unsafe(
          "/uploads/Catalog/productImages/a/dock.png",
        ),
      }),
    )
  )

  // A reshoot before placement is captured; the point of freezing is that one
  // *after* placement is not, which the order's own row then keeps proving.
  test("the picture in force at placement wins over an earlier one", () =>
    givenEvents([
      CatalogProductSynced({productId: "p1", name: "Fathom Dock"}),
      CatalogProductImageChanged({
        productId: "p1",
        productImage: Reventless.UploadableImage.unsafe("/uploads/Catalog/productImages/a/old.png"),
      }),
      CatalogProductImageChanged({
        productId: "p1",
        productImage: Reventless.UploadableImage.unsafe("/uploads/Catalog/productImages/a/new.png"),
      }),
    ])
    ->whenCmd(
      PlaceOrder({orderId: "o1", customerId: "c1", productIds: ["p1"], shippingMethod: Standard}),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        shippingMethod: Standard,
        firstProductName: "Fathom Dock",
        firstProductImage: Reventless.UploadableImage.unsafe(
          "/uploads/Catalog/productImages/a/new.png",
        ),
      }),
    )
  )

  // The case the absence exists for. A picture removed *before* placement must
  // not be frozen onto the order: the order records what was bought, and at that
  // moment there was no picture. Freezing the old one would be staleness wearing
  // freezing's clothes — and it is what happened while the announcement could
  // only ever carry a ref.
  test("a picture removed before placement is not frozen onto the order", () =>
    givenEvents([
      CatalogProductSynced({productId: "p1", name: "Fathom Dock"}),
      CatalogProductImageChanged({
        productId: "p1",
        productImage: Reventless.UploadableImage.unsafe("/uploads/Catalog/productImages/a/dock.png"),
      }),
      CatalogProductImageChanged({productId: "p1"}),
    ])
    ->whenCmd(
      PlaceOrder({orderId: "o1", customerId: "c1", productIds: ["p1"], shippingMethod: Standard}),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        shippingMethod: Standard,
        firstProductName: "Fathom Dock",
      }),
    )
  )

  // A product with no picture yet orders perfectly well — the field simply is
  // not there, which is what keeps this additive for every order already placed.
  test("an order for a product with no picture records none", () =>
    givenEvents([CatalogProductSynced({productId: "p1", name: "Fathom Dock"})])
    ->whenCmd(
      PlaceOrder({orderId: "o1", customerId: "c1", productIds: ["p1"], shippingMethod: Standard}),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        shippingMethod: Standard,
        firstProductName: "Fathom Dock",
      }),
    )
  )

  test("re-placing the same orderId returns OrderAlreadyPlaced", () =>
    givenEvents([CatalogProductSynced({productId: "p1", name: "Fathom Dock"}), OrderPlaced({orderId: "o1"})])
    ->whenCmd(
      PlaceOrder({orderId: "o1", customerId: "c1", productIds: ["p1"], shippingMethod: Standard}),
    )
    ->thenError(OrderAlreadyPlaced)
  )

  test("a sibling OrderPlaced for a different orderId does not block placement", () =>
    givenEvents([CatalogProductSynced({productId: "p1", name: "Fathom Dock"}), OrderPlaced({orderId: "o2"})])
    ->whenCmd(
      PlaceOrder({orderId: "o1", customerId: "c1", productIds: ["p1"], shippingMethod: Pickup}),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        shippingMethod: Pickup,
        firstProductName: "Fathom Dock",
      }),
    )
  )
})
