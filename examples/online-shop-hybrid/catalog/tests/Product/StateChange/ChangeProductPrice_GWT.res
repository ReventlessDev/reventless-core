@@reventless.gwt

open Catalog_Examples

// Prices are money, so a test writes the amount a person would say and converts
// it once. `ofMajor` scales by the currency's own exponent, which is what keeps
// the literal honest: 9.99 EUR is 999 cents, and the same call on a JPY price
// would scale by 1.

describe("ChangeProductPrice StateChangeSlice", () => {
  // scenario-id: 81859032-2d11-4921-8316-f1e782f815c4
  test("non-existent product returns ProductNotFound", () =>
    givenEvents([])
    ->whenCmd(
      ChangeProductPrice({
        productId: p1,
        price: Reventless.Money.make(~amount=100.0, ~currency=Reventless.Currency.EUR),
      }),
    )
    ->thenError(ProductNotFound)
  )

  // scenario-id: 4a08799f-22f9-41b3-be97-7a3872d1b28e
  test("existing product produces ProductPriceChanged", () =>
    givenEvents([ProductAdded({price: laptopPrice})])
    ->whenCmd(ChangeProductPrice({productId: p1, price: laptopChangedPrice}))
    ->thenEvent(ProductPriceChanged({productId: p1, price: laptopChangedPrice}))
  )

  // scenario-id: 5f305cf8-078a-440e-b0e6-795499ae14d7
  test("same price produces no events (idempotent)", () =>
    givenEvents([ProductAdded({price: laptopPrice})])
    ->whenCmd(ChangeProductPrice({productId: p1, price: laptopPrice}))
    ->thenNoEvent
  )

  // The second half of the from-set, and the reason it has two states: a product
  // pulled from the catalog for a season is coming back, and its price should be
  // right when it does.
  // scenario-id: 96db9326-54c8-4bbc-ba6a-6ac7a81a6b32
  test("repricing an archived product is allowed", () =>
    givenEvents([ProductAdded({price: laptopPrice}), ProductArchived])
    ->whenCmd(ChangeProductPrice({productId: p1, price: laptopChangedPrice}))
    ->thenEvent(ProductPriceChanged({productId: p1, price: laptopChangedPrice}))
  )

  // scenario-id: 5939fa12-8d5d-4760-8a33-1f234247bfdb
  test("repricing a discontinued product is refused", () =>
    givenEvents([ProductAdded({price: laptopPrice}), ProductDiscontinued])
    ->whenCmd(ChangeProductPrice({productId: p1, price: laptopChangedPrice}))
    ->thenError(ProductIsDiscontinued)
  )
})

describe("Who may ChangeProductPrice", () => {
  // scenario-id: 9687b7a9-3166-4371-bba6-fd4698b519cf
  test("a Merchandiser may reprice a product", () =>
    givenEvents([ProductAdded({price: laptopPrice})])
    ->asCaller(Caller.inRoles([Merchandiser]))
    ->whenCmd(ChangeProductPrice({productId: p1, price: laptopChangedPrice}))
    ->thenEvent(ProductPriceChanged({productId: p1, price: laptopChangedPrice}))
  )

  // scenario-id: 184d3f59-516d-46e2-83a3-ec1b15aa0f9e
  test("an Admin may reprice a product", () =>
    givenEvents([ProductAdded({price: laptopPrice})])
    ->asCaller(Caller.inRoles([Admin]))
    ->whenCmd(ChangeProductPrice({productId: p1, price: laptopChangedPrice}))
    ->thenEvent(ProductPriceChanged({productId: p1, price: laptopChangedPrice}))
  )

  // scenario-id: f9a60394-73e3-46ed-9a09-f276180312dd
  test("a shopper may not reprice a product", () =>
    givenEvents([ProductAdded({price: laptopPrice})])
    ->asCaller(Caller.owner(shopper))
    ->whenCmd(ChangeProductPrice({productId: p1, price: laptopChangedPrice}))
    ->thenRefused
  )

  // scenario-id: 939488ab-716d-420b-ae89-a6a637f394f4
  test("an anonymous caller may not reprice a product", () =>
    givenEvents([ProductAdded({price: laptopPrice})])
    ->asCaller(Caller.anonymous)
    ->whenCmd(ChangeProductPrice({productId: p1, price: laptopChangedPrice}))
    ->thenRefused
  )
})
