@@reventless.gwt

// Prices are money now, so a test writes the amount a person would say and
// converts it once. `ofMajor` scales by the currency's own exponent, which is
// what keeps the literal honest: 9.99 EUR is 999 cents, and the same call on a
// JPY price would scale by 1.
let eur = amount => Reventless.Money.ofMajor(~amount, ~currency=EUR)

describe("ChangeProductPrice StateChangeSlice", () => {
  test("non-existent product returns ProductNotFound", () =>
    givenEvents([])
    ->whenCmd(ChangeProductPrice({productId: "p1", price: eur(1.0)}))
    ->thenError(ProductNotFound)
  )

  test("existing product produces ProductPriceChanged", () =>
    givenEvents([ProductAdded({price: eur(999.99)})])
    ->whenCmd(ChangeProductPrice({productId: "p1", price: eur(899.99)}))
    ->thenEvent(ProductPriceChanged({productId: "p1", price: eur(899.99)}))
  )

  test("same price produces no events (idempotent)", () =>
    givenEvents([ProductAdded({price: eur(999.99)})])
    ->whenCmd(ChangeProductPrice({productId: "p1", price: eur(999.99)}))
    ->thenNoEvent
  )

  // The second half of the from-set, and the reason it has two states: a product
  // pulled from the catalog for a season is coming back, and its price should be
  // right when it does.
  test("repricing an archived product is allowed", () =>
    givenEvents([ProductAdded({price: eur(999.99)}), ProductArchived])
    ->whenCmd(ChangeProductPrice({productId: "p1", price: eur(899.99)}))
    ->thenEvent(ProductPriceChanged({productId: "p1", price: eur(899.99)}))
  )

  test("repricing a discontinued product is refused", () =>
    givenEvents([ProductAdded({price: eur(999.99)}), ProductDiscontinued])
    ->whenCmd(ChangeProductPrice({productId: "p1", price: eur(899.99)}))
    ->thenError(ProductIsDiscontinued)
  )
})
