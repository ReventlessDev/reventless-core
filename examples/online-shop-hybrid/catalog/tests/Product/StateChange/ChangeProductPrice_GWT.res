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
