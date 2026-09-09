@@reventless.gwt

// Minor units, the way `Money` counts them: 2500 is €25.00.
let eur = amount => Reventless.Money.make(~amount, ~currency=EUR)
let usd = amount => Reventless.Money.make(~amount, ~currency=USD)

let synced = (~id, ~name, ~price=2500.0) => CatalogProductSynced({
  productId: id,
  name,
  price: eur(price),
})

let relisted = (~id, ~name, ~price=2500.0) => CatalogProductRelisted({
  productId: id,
  name,
  price: eur(price),
})

let line = (~id, ~qty=1): lineItem => {productId: id, quantity: qty}

let placed = (~id, ~name, ~qty=1, ~price=2500.0): orderLine => {
  productId: id,
  name,
  quantity: qty,
  unitPrice: eur(price),
  lineTotal: eur(price *. qty->Int.toFloat),
}

describe("PlaceOrder StateChangeSlice", () => {
  test("requires referenced products to be synced first", () =>
    givenEvents([])
    ->whenCmd(
      PlaceOrder({
        orderId: "o1",
        customerId: "c1",
        lineItems: [line(~id="p1")],
        shippingMethod: Standard,
      }),
    )
    ->thenError(ProductsNotAvailable({missing: ["p1"]}))
  )

  test("placement succeeds when products are available", () =>
    givenEvents([synced(~id="p1", ~name="Fathom Dock")])
    ->whenCmd(
      PlaceOrder({
        orderId: "o1",
        customerId: "c1",
        lineItems: [line(~id="p1")],
        shippingMethod: Standard,
      }),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        lines: [placed(~id="p1", ~name="Fathom Dock")],
        total: eur(2500.0),
        shippingMethod: Standard,
        firstProductName: "Fathom Dock",
      }),
    )
  )

  // What line items are for. The quantity multiplies the shelf price the fold
  // holds, and the order's total is the sum of the lines — both computed at the
  // decision, from the log the decision already reads.
  test("a two-line order records a quantity per line and a total", () =>
    givenEvents([
      synced(~id="p1", ~name="Fathom Dock", ~price=2500.0),
      synced(~id="p2", ~name="Cirrus Charger", ~price=1000.0),
    ])
    ->whenCmd(
      PlaceOrder({
        orderId: "o1",
        customerId: "c1",
        lineItems: [line(~id="p1", ~qty=2), line(~id="p2")],
        shippingMethod: Standard,
      }),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1", "p2"],
        lines: [
          placed(~id="p1", ~name="Fathom Dock", ~qty=2, ~price=2500.0),
          placed(~id="p2", ~name="Cirrus Charger", ~price=1000.0),
        ],
        total: eur(6000.0),
        shippingMethod: Standard,
        firstProductName: "Fathom Dock",
      }),
    )
  )

  // An order for the same thing twice is one line of two. Merging at the decision
  // is what keeps the read side and the extension point from having to think
  // about a repeated product at all.
  test("two lines for the same product merge into one", () =>
    givenEvents([synced(~id="p1", ~name="Fathom Dock", ~price=2500.0)])
    ->whenCmd(
      PlaceOrder({
        orderId: "o1",
        customerId: "c1",
        lineItems: [line(~id="p1", ~qty=2), line(~id="p1")],
        shippingMethod: Standard,
      }),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        lines: [placed(~id="p1", ~name="Fathom Dock", ~qty=3, ~price=2500.0)],
        total: eur(7500.0),
        shippingMethod: Standard,
        firstProductName: "Fathom Dock",
      }),
    )
  )

  // The price the decision model held, not the one in force afterwards. A
  // repricing *before* placement is what the order records; the freezing is what
  // stops a later one rewriting an order already placed.
  test("a repricing before placement is the price the order records", () =>
    givenEvents([
      synced(~id="p1", ~name="Fathom Dock", ~price=2500.0),
      CatalogProductPriceChanged({productId: "p1", price: eur(1800.0)}),
    ])
    ->whenCmd(
      PlaceOrder({
        orderId: "o1",
        customerId: "c1",
        lineItems: [line(~id="p1", ~qty=2)],
        shippingMethod: Standard,
      }),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        lines: [placed(~id="p1", ~name="Fathom Dock", ~qty=2, ~price=1800.0)],
        total: eur(3600.0),
        shippingMethod: Standard,
        firstProductName: "Fathom Dock",
      }),
    )
  )

  // The one validation a shopper could trip before line items existed: an empty
  // basket placed an order for nothing.
  test("an empty basket is refused", () =>
    givenEvents([synced(~id="p1", ~name="Fathom Dock")])
    ->whenCmd(
      PlaceOrder({orderId: "o1", customerId: "c1", lineItems: [], shippingMethod: Standard}),
    )
    ->thenError(OrderIsEmpty)
  )

  test("a zero quantity is refused", () =>
    givenEvents([synced(~id="p1", ~name="Fathom Dock")])
    ->whenCmd(
      PlaceOrder({
        orderId: "o1",
        customerId: "c1",
        lineItems: [line(~id="p1", ~qty=0)],
        shippingMethod: Standard,
      }),
    )
    ->thenError(InvalidQuantity({productId: "p1", quantity: 0}))
  )

  test("a negative quantity is refused", () =>
    givenEvents([synced(~id="p1", ~name="Fathom Dock")])
    ->whenCmd(
      PlaceOrder({
        orderId: "o1",
        customerId: "c1",
        lineItems: [line(~id="p1", ~qty=-2)],
        shippingMethod: Standard,
      }),
    )
    ->thenError(InvalidQuantity({productId: "p1", quantity: -2}))
  )

  // Refused rather than silently summed. `Money.add` returns a `result` for
  // exactly this, and unwrapping it would invent a total in whichever currency
  // happened to come first.
  test("an order mixing currencies is refused rather than summed", () =>
    givenEvents([
      synced(~id="p1", ~name="Fathom Dock", ~price=2500.0),
      CatalogProductSynced({productId: "p2", name: "Cirrus Charger", price: usd(1000.0)}),
    ])
    ->whenCmd(
      PlaceOrder({
        orderId: "o1",
        customerId: "c1",
        lineItems: [line(~id="p1"), line(~id="p2")],
        shippingMethod: Standard,
      }),
    )
    ->thenError(MixedCurrencies({currencies: ["EUR", "USD"]}))
  )

  test("the chosen shipping method is carried onto the event", () =>
    givenEvents([synced(~id="p1", ~name="Fathom Dock")])
    ->whenCmd(
      PlaceOrder({
        orderId: "o1",
        customerId: "c1",
        lineItems: [line(~id="p1")],
        shippingMethod: Express,
      }),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        lines: [placed(~id="p1", ~name="Fathom Dock")],
        total: eur(2500.0),
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
    let window =
      Reventless.DateRange.make(
        ~start="2026-03-02T09:00:00Z",
        ~end_="2026-03-02T11:00:00Z",
      )->Result.getOrThrow
    givenEvents([synced(~id="p1", ~name="Fathom Dock")])
    ->whenCmd(
      PlaceOrder({
        orderId: "o1",
        customerId: "c1",
        lineItems: [line(~id="p1")],
        shippingMethod: Standard,
        deliveryWindow: window,
      }),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        lines: [placed(~id="p1", ~name="Fathom Dock")],
        total: eur(2500.0),
        shippingMethod: Standard,
        deliveryWindow: window,
        firstProductName: "Fathom Dock",
      }),
    )
  })

  test("partial product availability returns ProductsNotAvailable with missing list", () =>
    givenEvents([synced(~id="p1", ~name="Fathom Dock")])
    ->whenCmd(
      PlaceOrder({
        orderId: "o1",
        customerId: "c1",
        lineItems: [line(~id="p1"), line(~id="p2")],
        shippingMethod: Standard,
      }),
    )
    ->thenError(ProductsNotAvailable({missing: ["p2"]}))
  )

  // The shelf lifecycle reaching the decision. The view deletes a withdrawn
  // product's row, so a shopper never sees it; these pin the write side to the
  // same answer, which is the half that was missing.
  test("a withdrawn product can no longer be ordered", () =>
    givenEvents([synced(~id="p1", ~name="Fathom Dock"), CatalogProductWithdrawn({productId: "p1"})])
    ->whenCmd(
      PlaceOrder({
        orderId: "o1",
        customerId: "c1",
        lineItems: [line(~id="p1")],
        shippingMethod: Standard,
      }),
    )
    ->thenError(ProductsNotAvailable({missing: ["p1"]}))
  )

  // Withdrawal removes one id, not the shelf.
  test("withdrawing one product leaves its siblings orderable", () =>
    givenEvents([
      synced(~id="p1", ~name="Fathom Dock"),
      synced(~id="p2", ~name="Cirrus Charger"),
      CatalogProductWithdrawn({productId: "p2"}),
    ])
    ->whenCmd(
      PlaceOrder({
        orderId: "o1",
        customerId: "c1",
        lineItems: [line(~id="p1")],
        shippingMethod: Standard,
      }),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        lines: [placed(~id="p1", ~name="Fathom Dock")],
        total: eur(2500.0),
        shippingMethod: Standard,
        firstProductName: "Fathom Dock",
      }),
    )
  )

  // A basket that mixes live and withdrawn stock names only what it refused.
  test("a basket naming a withdrawn product reports just that product as missing", () =>
    givenEvents([
      synced(~id="p1", ~name="Fathom Dock"),
      synced(~id="p2", ~name="Cirrus Charger"),
      CatalogProductWithdrawn({productId: "p2"}),
    ])
    ->whenCmd(
      PlaceOrder({
        orderId: "o1",
        customerId: "c1",
        lineItems: [line(~id="p1"), line(~id="p2")],
        shippingMethod: Standard,
      }),
    )
    ->thenError(ProductsNotAvailable({missing: ["p2"]}))
  )

  // And the way back. A relist that did not restore orderability would break the
  // lifecycle in the other direction — off the shelf permanently.
  test("a relisted product can be ordered again", () =>
    givenEvents([
      synced(~id="p1", ~name="Fathom Dock"),
      CatalogProductWithdrawn({productId: "p1"}),
      relisted(~id="p1", ~name="Fathom Dock"),
    ])
    ->whenCmd(
      PlaceOrder({
        orderId: "o1",
        customerId: "c1",
        lineItems: [line(~id="p1")],
        shippingMethod: Standard,
      }),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        lines: [placed(~id="p1", ~name="Fathom Dock")],
        total: eur(2500.0),
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
      synced(~id="p1", ~name="Fathom Dock"),
      synced(~id="p1", ~name="Fathom Dock 4-Port"),
    ])
    ->whenCmd(
      PlaceOrder({
        orderId: "o1",
        customerId: "c1",
        lineItems: [line(~id="p1")],
        shippingMethod: Standard,
      }),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        lines: [placed(~id="p1", ~name="Fathom Dock 4-Port")],
        total: eur(2500.0),
        shippingMethod: Standard,
        firstProductName: "Fathom Dock 4-Port",
      }),
    )
  )

  // The FIRST product names the order, and a basket is ordered. Naming the
  // basket after whichever product the fold happened to see last would make the
  // same order read differently depending on catalog traffic.
  test("a basket is named after its first product, not its last", () =>
    givenEvents([synced(~id="p1", ~name="Fathom Dock"), synced(~id="p2", ~name="Cirrus Charger")])
    ->whenCmd(
      PlaceOrder({
        orderId: "o1",
        customerId: "c1",
        lineItems: [line(~id="p2"), line(~id="p1")],
        shippingMethod: Standard,
      }),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p2", "p1"],
        lines: [placed(~id="p2", ~name="Cirrus Charger"), placed(~id="p1", ~name="Fathom Dock")],
        total: eur(5000.0),
        shippingMethod: Standard,
        firstProductName: "Cirrus Charger",
      }),
    )
  )

  // The picture travels the same road as the name, and freezes the same way.
  test("the first product's picture is captured onto the event", () =>
    givenEvents([
      synced(~id="p1", ~name="Fathom Dock"),
      CatalogProductImageChanged({
        productId: "p1",
        productImage: Reventless.UploadableImage.unsafe(
          "/uploads/Catalog/productImages/a/dock.png",
        ),
      }),
    ])
    ->whenCmd(
      PlaceOrder({
        orderId: "o1",
        customerId: "c1",
        lineItems: [line(~id="p1")],
        shippingMethod: Standard,
      }),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        lines: [placed(~id="p1", ~name="Fathom Dock")],
        total: eur(2500.0),
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
      synced(~id="p1", ~name="Fathom Dock"),
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
      PlaceOrder({
        orderId: "o1",
        customerId: "c1",
        lineItems: [line(~id="p1")],
        shippingMethod: Standard,
      }),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        lines: [placed(~id="p1", ~name="Fathom Dock")],
        total: eur(2500.0),
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
      synced(~id="p1", ~name="Fathom Dock"),
      CatalogProductImageChanged({
        productId: "p1",
        productImage: Reventless.UploadableImage.unsafe(
          "/uploads/Catalog/productImages/a/dock.png",
        ),
      }),
      CatalogProductImageChanged({productId: "p1"}),
    ])
    ->whenCmd(
      PlaceOrder({
        orderId: "o1",
        customerId: "c1",
        lineItems: [line(~id="p1")],
        shippingMethod: Standard,
      }),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        lines: [placed(~id="p1", ~name="Fathom Dock")],
        total: eur(2500.0),
        shippingMethod: Standard,
        firstProductName: "Fathom Dock",
      }),
    )
  )

  // A product with no picture yet orders perfectly well — the field simply is
  // not there, which is what keeps this additive for every order already placed.
  test("an order for a product with no picture records none", () =>
    givenEvents([synced(~id="p1", ~name="Fathom Dock")])
    ->whenCmd(
      PlaceOrder({
        orderId: "o1",
        customerId: "c1",
        lineItems: [line(~id="p1")],
        shippingMethod: Standard,
      }),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        lines: [placed(~id="p1", ~name="Fathom Dock")],
        total: eur(2500.0),
        shippingMethod: Standard,
        firstProductName: "Fathom Dock",
      }),
    )
  )

  test("re-placing the same orderId returns OrderAlreadyPlaced", () =>
    givenEvents([synced(~id="p1", ~name="Fathom Dock"), OrderPlaced({orderId: "o1"})])
    ->whenCmd(
      PlaceOrder({
        orderId: "o1",
        customerId: "c1",
        lineItems: [line(~id="p1")],
        shippingMethod: Standard,
      }),
    )
    ->thenError(OrderAlreadyPlaced)
  )

  test("a sibling OrderPlaced for a different orderId does not block placement", () =>
    givenEvents([synced(~id="p1", ~name="Fathom Dock"), OrderPlaced({orderId: "o2"})])
    ->whenCmd(
      PlaceOrder({
        orderId: "o1",
        customerId: "c1",
        lineItems: [line(~id="p1")],
        shippingMethod: Pickup,
      }),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        lines: [placed(~id="p1", ~name="Fathom Dock")],
        total: eur(2500.0),
        shippingMethod: Pickup,
        firstProductName: "Fathom Dock",
      }),
    )
  )
})
