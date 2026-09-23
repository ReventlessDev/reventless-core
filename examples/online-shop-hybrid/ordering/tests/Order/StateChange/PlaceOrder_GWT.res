@@reventless.gwt

open Ordering_Examples
open PlaceOrder_Examples

describe("PlaceOrder StateChangeSlice", () => {
  // scenario-id: 9992fb4f-24fd-4f30-819e-bb2d99b95aea
  test("requires referenced products to be synced first", () =>
    givenEvents([])
    ->whenCmd(
      PlaceOrder({
        orderId: o1,
        customerId: c1,
        lineItems: [{productId: p1, quantity: 1}],
        shippingMethod: Standard,
      }),
    )
    ->thenError(ProductsNotAvailable({missing: [p1]}))
  )

  // scenario-id: 7e494f69-e2bf-4727-8c51-08317ca42e0d
  test("placement succeeds when products are available", () =>
    givenEvents([
      CatalogProductSynced({
        productId: p1,
        name: fathomDock,
        price: dockPrice,
      }),
    ])
    ->whenCmd(
      PlaceOrder({
        orderId: o1,
        customerId: c1,
        lineItems: [{productId: p1, quantity: 1}],
        shippingMethod: Standard,
      }),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: o1,
        customerId: c1,
        productIds: [p1],
        lines: [dockLine],
        total: dockPrice,
        shippingMethod: Standard,
        firstProductName: fathomDock,
      }),
    )
  )

  // What line items are for. The quantity multiplies the shelf price the fold
  // holds, and the order's total is the sum of the lines — both computed at the
  // decision, from the log the decision already reads.
  // scenario-id: 690caf70-4b22-4ef1-8be2-7c79c6d725e9
  test("a two-line order records a quantity per line and a total", () =>
    givenEvents([
      CatalogProductSynced({
        productId: p1,
        name: fathomDock,
        price: dockPrice,
      }),
      CatalogProductSynced({
        productId: p2,
        name: cirrusCharger,
        price: Reventless.Money.make(~amount=1000.0, ~currency=Reventless.Currency.EUR),
      }),
    ])
    ->whenCmd(
      PlaceOrder({
        orderId: o1,
        customerId: c1,
        lineItems: [{productId: p1, quantity: 2}, {productId: p2, quantity: 1}],
        shippingMethod: Standard,
      }),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: o1,
        customerId: c1,
        productIds: [p1, p2],
        lines: [
          {
            productId: p1,
            name: fathomDock,
            quantity: 2,
            unitPrice: dockPrice,
            lineTotal: Reventless.Money.make(~amount=5000.0, ~currency=Reventless.Currency.EUR),
          },
          {
            productId: p2,
            name: cirrusCharger,
            quantity: 1,
            unitPrice: Reventless.Money.make(~amount=1000.0, ~currency=Reventless.Currency.EUR),
            lineTotal: Reventless.Money.make(~amount=1000.0, ~currency=Reventless.Currency.EUR),
          },
        ],
        total: Reventless.Money.make(~amount=6000.0, ~currency=Reventless.Currency.EUR),
        shippingMethod: Standard,
        firstProductName: fathomDock,
      }),
    )
  )

  // An order for the same thing twice is one line of two. Merging at the decision
  // is what keeps the read side and the extension point from having to think
  // about a repeated product at all.
  // scenario-id: f032c153-dc10-48b0-8e45-c4045ae31948
  test("two lines for the same product merge into one", () =>
    givenEvents([
      CatalogProductSynced({
        productId: p1,
        name: fathomDock,
        price: dockPrice,
      }),
    ])
    ->whenCmd(
      PlaceOrder({
        orderId: o1,
        customerId: c1,
        lineItems: [{productId: p1, quantity: 2}, {productId: p1, quantity: 1}],
        shippingMethod: Standard,
      }),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: o1,
        customerId: c1,
        productIds: [p1],
        lines: [
          {
            productId: p1,
            name: fathomDock,
            quantity: 3,
            unitPrice: dockPrice,
            lineTotal: Reventless.Money.make(~amount=7500.0, ~currency=Reventless.Currency.EUR),
          },
        ],
        total: Reventless.Money.make(~amount=7500.0, ~currency=Reventless.Currency.EUR),
        shippingMethod: Standard,
        firstProductName: fathomDock,
      }),
    )
  )

  // The price the decision model held, not the one in force afterwards. A
  // repricing *before* placement is what the order records; the freezing is what
  // stops a later one rewriting an order already placed.
  // scenario-id: d709b66b-900d-4420-b377-a1d306deb0b8
  test("a repricing before placement is the price the order records", () =>
    givenEvents([
      CatalogProductSynced({
        productId: p1,
        name: fathomDock,
        price: dockPrice,
      }),
      CatalogProductPriceChanged({
        productId: p1,
        price: Reventless.Money.make(~amount=1800.0, ~currency=Reventless.Currency.EUR),
      }),
    ])
    ->whenCmd(
      PlaceOrder({
        orderId: o1,
        customerId: c1,
        lineItems: [{productId: p1, quantity: 2}],
        shippingMethod: Standard,
      }),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: o1,
        customerId: c1,
        productIds: [p1],
        lines: [
          {
            productId: p1,
            name: fathomDock,
            quantity: 2,
            unitPrice: Reventless.Money.make(~amount=1800.0, ~currency=Reventless.Currency.EUR),
            lineTotal: Reventless.Money.make(~amount=3600.0, ~currency=Reventless.Currency.EUR),
          },
        ],
        total: Reventless.Money.make(~amount=3600.0, ~currency=Reventless.Currency.EUR),
        shippingMethod: Standard,
        firstProductName: fathomDock,
      }),
    )
  )

  // The one validation a shopper could trip before line items existed: an empty
  // basket placed an order for nothing.
  // scenario-id: eef3978a-4cf9-42b6-8f22-2ba767ce8c8b
  test("an empty basket is refused", () =>
    givenEvents([
      CatalogProductSynced({
        productId: p1,
        name: fathomDock,
        price: dockPrice,
      }),
    ])
    ->whenCmd(
      PlaceOrder({
        orderId: o1,
        customerId: c1,
        lineItems: [],
        shippingMethod: Standard,
      }),
    )
    ->thenError(OrderIsEmpty)
  )

  // scenario-id: 77a010c2-0fbd-41f1-9cf2-182c2c6ec9c7
  test("a zero quantity is refused", () =>
    givenEvents([
      CatalogProductSynced({
        productId: p1,
        name: fathomDock,
        price: dockPrice,
      }),
    ])
    ->whenCmd(
      PlaceOrder({
        orderId: o1,
        customerId: c1,
        lineItems: [{productId: p1, quantity: 0}],
        shippingMethod: Standard,
      }),
    )
    ->thenError(InvalidQuantity({productId: p1, quantity: 0}))
  )

  // scenario-id: 124a3e0f-323b-4179-af52-db73d142172e
  test("a negative quantity is refused", () =>
    givenEvents([
      CatalogProductSynced({
        productId: p1,
        name: fathomDock,
        price: dockPrice,
      }),
    ])
    ->whenCmd(
      PlaceOrder({
        orderId: o1,
        customerId: c1,
        lineItems: [{productId: p1, quantity: -2}],
        shippingMethod: Standard,
      }),
    )
    ->thenError(InvalidQuantity({productId: p1, quantity: -2}))
  )

  // Refused rather than silently summed. `Money.add` returns a `result` for
  // exactly this, and unwrapping it would invent a total in whichever currency
  // happened to come first.
  // scenario-id: 8c1c6e52-f45c-48f9-bd16-fc5aebc4ce5f
  test("an order mixing currencies is refused rather than summed", () =>
    givenEvents([
      CatalogProductSynced({
        productId: p1,
        name: fathomDock,
        price: dockPrice,
      }),
      CatalogProductSynced({
        productId: p2,
        name: cirrusCharger,
        price: Reventless.Money.make(~amount=1000.0, ~currency=Reventless.Currency.USD),
      }),
    ])
    ->whenCmd(
      PlaceOrder({
        orderId: o1,
        customerId: c1,
        lineItems: [{productId: p1, quantity: 1}, {productId: p2, quantity: 1}],
        shippingMethod: Standard,
      }),
    )
    ->thenError(MixedCurrencies({currencies: ["EUR", "USD"]}))
  )

  // scenario-id: 2f0eb8f8-383e-4eaf-9dac-7c76523f5917
  test("the chosen shipping method is carried onto the event", () =>
    givenEvents([
      CatalogProductSynced({
        productId: p1,
        name: fathomDock,
        price: dockPrice,
      }),
    ])
    ->whenCmd(
      PlaceOrder({
        orderId: o1,
        customerId: c1,
        lineItems: [{productId: p1, quantity: 1}],
        shippingMethod: Express,
      }),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: o1,
        customerId: c1,
        productIds: [p1],
        lines: [dockLine],
        total: dockPrice,
        shippingMethod: Express,
        firstProductName: fathomDock,
      }),
    )
  )

  // The requested delivery slot is a single `DateRange`, not a `start*`/`end*`
  // name pair, and it rides the command straight onto the event unchanged. A
  // Standard order can still ask for a window; an order that omits it carries no
  // key at all (the optional field above).
  // scenario-id: 62bcf414-0399-4204-a3cb-91238a3d6988
  test("a requested delivery window is carried onto the event", () => {
    let window =
      Reventless.DateRange.make(
        ~start="2026-03-02T09:00:00Z",
        ~end_="2026-03-02T11:00:00Z",
      )->Result.getOrThrow
    givenEvents([
      CatalogProductSynced({
        productId: p1,
        name: fathomDock,
        price: dockPrice,
      }),
    ])
    ->whenCmd(
      PlaceOrder({
        orderId: o1,
        customerId: c1,
        lineItems: [{productId: p1, quantity: 1}],
        shippingMethod: Standard,
        deliveryWindow: window,
      }),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: o1,
        customerId: c1,
        productIds: [p1],
        lines: [dockLine],
        total: dockPrice,
        shippingMethod: Standard,
        deliveryWindow: window,
        firstProductName: fathomDock,
      }),
    )
  })

  // scenario-id: ca25e708-7719-4c72-b00f-34a6efbd5725
  test("a delivery window on a pickup order is refused", () => {
    let window =
      Reventless.DateRange.make(
        ~start="2026-03-02T09:00:00Z",
        ~end_="2026-03-02T11:00:00Z",
      )->Result.getOrThrow
    givenEvents([
      CatalogProductSynced({
        productId: p1,
        name: fathomDock,
        price: dockPrice,
      }),
    ])
    ->whenCmd(
      PlaceOrder({
        orderId: o1,
        customerId: c1,
        lineItems: [{productId: p1, quantity: 1}],
        shippingMethod: Pickup,
        deliveryWindow: window,
      }),
    )
    ->thenError(DeliveryWindowOnPickup)
  })

  // Built as a record rather than through `DateRange.make`, which would refuse
  // it: a client sends JSON, and decoding does not apply the ordering rule.
  // scenario-id: c0f4a0de-82c6-4766-b7b6-1f43a1b88fb4
  test("a delivery window that ends before it starts is refused", () => {
    let reversed = {
      Reventless.DateRange.start: "2026-03-02T11:00:00Z",
      end_: "2026-03-02T09:00:00Z",
    }
    givenEvents([
      CatalogProductSynced({
        productId: p1,
        name: fathomDock,
        price: dockPrice,
      }),
    ])
    ->whenCmd(
      PlaceOrder({
        orderId: o1,
        customerId: c1,
        lineItems: [{productId: p1, quantity: 1}],
        shippingMethod: Standard,
        deliveryWindow: reversed,
      }),
    )
    ->thenError(
      InvalidDeliveryWindow({
        reason: switch Reventless.DateRange.validate(reversed) {
        | Error(reason) => reason
        | Ok(_) => "expected the ordering rule to refuse this range"
        },
      }),
    )
  })

  // scenario-id: 78f1da09-485a-4a23-9972-f2842ef0275f
  test("partial product availability returns ProductsNotAvailable with missing list", () =>
    givenEvents([
      CatalogProductSynced({
        productId: p1,
        name: fathomDock,
        price: dockPrice,
      }),
    ])
    ->whenCmd(
      PlaceOrder({
        orderId: o1,
        customerId: c1,
        lineItems: [{productId: p1, quantity: 1}, {productId: p2, quantity: 1}],
        shippingMethod: Standard,
      }),
    )
    ->thenError(ProductsNotAvailable({missing: [p2]}))
  )

  // The shelf lifecycle reaching the decision. The view deletes a withdrawn
  // product's row, so a shopper never sees it; these pin the write side to the
  // same answer, which is the half that was missing.
  // scenario-id: 69699588-6b32-4822-8027-4d0670e46107
  test("a withdrawn product can no longer be ordered", () =>
    givenEvents([
      CatalogProductSynced({
        productId: p1,
        name: fathomDock,
        price: dockPrice,
      }),
      CatalogProductWithdrawn({productId: p1}),
    ])
    ->whenCmd(
      PlaceOrder({
        orderId: o1,
        customerId: c1,
        lineItems: [{productId: p1, quantity: 1}],
        shippingMethod: Standard,
      }),
    )
    ->thenError(ProductsNotAvailable({missing: [p1]}))
  )

  // Withdrawal removes one id, not the shelf.
  // scenario-id: 985b1b8f-25a5-49f3-823c-4a1282eace2f
  test("withdrawing one product leaves its siblings orderable", () =>
    givenEvents([
      CatalogProductSynced({
        productId: p1,
        name: fathomDock,
        price: dockPrice,
      }),
      CatalogProductSynced({
        productId: p2,
        name: cirrusCharger,
        price: dockPrice,
      }),
      CatalogProductWithdrawn({productId: p2}),
    ])
    ->whenCmd(
      PlaceOrder({
        orderId: o1,
        customerId: c1,
        lineItems: [{productId: p1, quantity: 1}],
        shippingMethod: Standard,
      }),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: o1,
        customerId: c1,
        productIds: [p1],
        lines: [dockLine],
        total: dockPrice,
        shippingMethod: Standard,
        firstProductName: fathomDock,
      }),
    )
  )

  // A basket that mixes live and withdrawn stock names only what it refused.
  // scenario-id: 3452de27-6351-4200-bbd5-373488cb07cc
  test("a basket naming a withdrawn product reports just that product as missing", () =>
    givenEvents([
      CatalogProductSynced({
        productId: p1,
        name: fathomDock,
        price: dockPrice,
      }),
      CatalogProductSynced({
        productId: p2,
        name: cirrusCharger,
        price: dockPrice,
      }),
      CatalogProductWithdrawn({productId: p2}),
    ])
    ->whenCmd(
      PlaceOrder({
        orderId: o1,
        customerId: c1,
        lineItems: [{productId: p1, quantity: 1}, {productId: p2, quantity: 1}],
        shippingMethod: Standard,
      }),
    )
    ->thenError(ProductsNotAvailable({missing: [p2]}))
  )

  // And the way back. A relist that did not restore orderability would break the
  // lifecycle in the other direction — off the shelf permanently.
  // scenario-id: 6ce5c57c-88ea-4f6f-9750-876b221074c2
  test("a relisted product can be ordered again", () =>
    givenEvents([
      CatalogProductSynced({
        productId: p1,
        name: fathomDock,
        price: dockPrice,
      }),
      CatalogProductWithdrawn({productId: p1}),
      CatalogProductRelisted({
        productId: p1,
        name: fathomDock,
        price: dockPrice,
      }),
    ])
    ->whenCmd(
      PlaceOrder({
        orderId: o1,
        customerId: c1,
        lineItems: [{productId: p1, quantity: 1}],
        shippingMethod: Standard,
      }),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: o1,
        customerId: c1,
        productIds: [p1],
        lines: [dockLine],
        total: dockPrice,
        shippingMethod: Standard,
        firstProductName: fathomDock,
      }),
    )
  )

  // What the order records about what was bought. The name is copied off the
  // shelf as it reads at placement, because an order is a record of a purchase
  // and the catalog goes on changing after it — a rename, a withdrawal. Reading
  // it live would rewrite history every time the shop tidied its shelves.
  // scenario-id: ea99eb66-c24a-44e4-8128-fa16bc528724
  test("a rename before placement is captured under the new name", () =>
    givenEvents([
      CatalogProductSynced({
        productId: p1,
        name: fathomDock,
        price: dockPrice,
      }),
      CatalogProductSynced({
        productId: p1,
        name: "Fathom Dock 4-Port",
        price: dockPrice,
      }),
    ])
    ->whenCmd(
      PlaceOrder({
        orderId: o1,
        customerId: c1,
        lineItems: [{productId: p1, quantity: 1}],
        shippingMethod: Standard,
      }),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: o1,
        customerId: c1,
        productIds: [p1],
        lines: [
          {
            productId: p1,
            name: "Fathom Dock 4-Port",
            quantity: 1,
            unitPrice: dockPrice,
            lineTotal: dockPrice,
          },
        ],
        total: dockPrice,
        shippingMethod: Standard,
        firstProductName: "Fathom Dock 4-Port",
      }),
    )
  )

  // The FIRST product names the order, and a basket is ordered. Naming the
  // basket after whichever product the fold happened to see last would make the
  // same order read differently depending on catalog traffic.
  // scenario-id: 46dda964-1001-43a7-8f22-20576f672139
  test("a basket is named after its first product, not its last", () =>
    givenEvents([
      CatalogProductSynced({
        productId: p1,
        name: fathomDock,
        price: dockPrice,
      }),
      CatalogProductSynced({
        productId: p2,
        name: cirrusCharger,
        price: dockPrice,
      }),
    ])
    ->whenCmd(
      PlaceOrder({
        orderId: o1,
        customerId: c1,
        lineItems: [{productId: p2, quantity: 1}, {productId: p1, quantity: 1}],
        shippingMethod: Standard,
      }),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: o1,
        customerId: c1,
        productIds: [p2, p1],
        lines: [
          {
            productId: p2,
            name: cirrusCharger,
            quantity: 1,
            unitPrice: dockPrice,
            lineTotal: dockPrice,
          },
          dockLine,
        ],
        total: Reventless.Money.make(~amount=5000.0, ~currency=Reventless.Currency.EUR),
        shippingMethod: Standard,
        firstProductName: cirrusCharger,
      }),
    )
  )

  // The picture travels the same road as the name, and freezes the same way.
  // scenario-id: 10416f19-34c2-499e-993e-c412616d4cba
  test("the first product's picture is captured onto the event", () =>
    givenEvents([
      CatalogProductSynced({
        productId: p1,
        name: fathomDock,
        price: dockPrice,
      }),
      CatalogProductImageChanged({
        productId: p1,
        productImage: Reventless.UploadableImage.unsafe(
          "/uploads/Catalog/productImages/a/dock.png",
        ),
      }),
    ])
    ->whenCmd(
      PlaceOrder({
        orderId: o1,
        customerId: c1,
        lineItems: [{productId: p1, quantity: 1}],
        shippingMethod: Standard,
      }),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: o1,
        customerId: c1,
        productIds: [p1],
        lines: [dockLine],
        total: dockPrice,
        shippingMethod: Standard,
        firstProductName: fathomDock,
        firstProductImage: Reventless.UploadableImage.unsafe(
          "/uploads/Catalog/productImages/a/dock.png",
        ),
      }),
    )
  )

  // A reshoot before placement is captured; the point of freezing is that one
  // *after* placement is not, which the order's own row then keeps proving.
  // scenario-id: e86fab72-c692-4f10-82a6-7a924c6a600d
  test("the picture in force at placement wins over an earlier one", () =>
    givenEvents([
      CatalogProductSynced({
        productId: p1,
        name: fathomDock,
        price: dockPrice,
      }),
      CatalogProductImageChanged({
        productId: p1,
        productImage: Reventless.UploadableImage.unsafe("/uploads/Catalog/productImages/a/old.png"),
      }),
      CatalogProductImageChanged({
        productId: p1,
        productImage: Reventless.UploadableImage.unsafe("/uploads/Catalog/productImages/a/new.png"),
      }),
    ])
    ->whenCmd(
      PlaceOrder({
        orderId: o1,
        customerId: c1,
        lineItems: [{productId: p1, quantity: 1}],
        shippingMethod: Standard,
      }),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: o1,
        customerId: c1,
        productIds: [p1],
        lines: [dockLine],
        total: dockPrice,
        shippingMethod: Standard,
        firstProductName: fathomDock,
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
  // scenario-id: 9d1fecc4-72b2-4d0d-9120-0dda4cee5c85
  test("a picture removed before placement is not frozen onto the order", () =>
    givenEvents([
      CatalogProductSynced({
        productId: p1,
        name: fathomDock,
        price: dockPrice,
      }),
      CatalogProductImageChanged({
        productId: p1,
        productImage: Reventless.UploadableImage.unsafe(
          "/uploads/Catalog/productImages/a/dock.png",
        ),
      }),
      CatalogProductImageChanged({productId: p1}),
    ])
    ->whenCmd(
      PlaceOrder({
        orderId: o1,
        customerId: c1,
        lineItems: [{productId: p1, quantity: 1}],
        shippingMethod: Standard,
      }),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: o1,
        customerId: c1,
        productIds: [p1],
        lines: [dockLine],
        total: dockPrice,
        shippingMethod: Standard,
        firstProductName: fathomDock,
      }),
    )
  )

  // A product with no picture yet orders perfectly well — the field simply is
  // not there, which is what keeps this additive for every order already placed.
  // scenario-id: d1dd8913-79ff-4bf9-aebb-7fbfa582d6ce
  test("an order for a product with no picture records none", () =>
    givenEvents([
      CatalogProductSynced({
        productId: p1,
        name: fathomDock,
        price: dockPrice,
      }),
    ])
    ->whenCmd(
      PlaceOrder({
        orderId: o1,
        customerId: c1,
        lineItems: [{productId: p1, quantity: 1}],
        shippingMethod: Standard,
      }),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: o1,
        customerId: c1,
        productIds: [p1],
        lines: [dockLine],
        total: dockPrice,
        shippingMethod: Standard,
        firstProductName: fathomDock,
      }),
    )
  )

  // scenario-id: 178067c0-6f46-4ca6-b1f4-ba808a223dd1
  test("re-placing the same orderId returns OrderAlreadyPlaced", () =>
    givenEvents([
      CatalogProductSynced({
        productId: p1,
        name: fathomDock,
        price: dockPrice,
      }),
      OrderPlaced({orderId: o1}),
    ])
    ->whenCmd(
      PlaceOrder({
        orderId: o1,
        customerId: c1,
        lineItems: [{productId: p1, quantity: 1}],
        shippingMethod: Standard,
      }),
    )
    ->thenError(OrderAlreadyPlaced)
  )

  // scenario-id: 12e7e9c1-c821-4f34-ad0c-9a890fd48f6e
  test("a sibling OrderPlaced for a different orderId does not block placement", () =>
    givenEvents([
      CatalogProductSynced({
        productId: p1,
        name: fathomDock,
        price: dockPrice,
      }),
      OrderPlaced({orderId: o2}),
    ])
    ->whenCmd(
      PlaceOrder({
        orderId: o1,
        customerId: c1,
        lineItems: [{productId: p1, quantity: 1}],
        shippingMethod: Pickup,
      }),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: o1,
        customerId: c1,
        productIds: [p1],
        lines: [dockLine],
        total: dockPrice,
        shippingMethod: Pickup,
        firstProductName: fathomDock,
      }),
    )
  )
})
