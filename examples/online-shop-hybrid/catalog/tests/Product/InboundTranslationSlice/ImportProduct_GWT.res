// `InboundTranslation_GWT.Make` expects a single SliceSpec carrying both the
// types (from the spec file) and the `translate` function (from the body
// file). Compose them locally before handing the result to the DSL.

module ImportProductSlice = {
  include ImportProduct
  let translate = ImportProduct_Translation.translate
}

@@reventless.gwt

// The feed counts in minor units and the domain counts in the currency's own,
// so the expectations are written the way a person says a price and the slice is
// left to do the conversion. That the two differ by exactly the currency's scale
// — ×100 for USD, ×1 for JPY — is what these cases are checking.
let money = (amount, currency) => Reventless.Money.make(~amount, ~currency)

describe("ImportProduct InboundTranslationSlice", () => {
  test("USD payload translates to AddProduct command", () =>
    whenInput({
      sku: "p-1",
      title: "Laptop",
      desc: "high-end",
      unitPrice: 99999,
      currency: "USD",
      category: "cat1",
    })
    ->thenCommand(
      "p-1",
      AddProduct({
        productId: "p-1",
        name: "Laptop",
        description: "high-end",
        price: money(999.99, USD),
        // Supplier feed carries no image → the optional productImage is absent.
        categoryId: "cat1",
      }),
    )
  )

  // The case the old translation could not express. It rejected every currency
  // but USD, because the domain had a `float` price and nowhere to record which
  // currency it was in. Now the currency survives, so a second one is ordinary
  // data rather than an unsupported case.
  test("a non-USD payload translates instead of failing", () =>
    whenInput({
      sku: "p-2",
      title: "Buch",
      desc: "gut",
      unitPrice: 1999,
      currency: "EUR",
      category: "cat1",
    })
    ->thenCommand(
      "p-2",
      AddProduct({
        productId: "p-2",
        name: "Buch",
        description: "gut",
        price: money(19.99, EUR),
        categoryId: "cat1",
      }),
    )
  )

  // And the case that would have been silently wrong under a hardcoded `/100`:
  // JPY has no minor unit, so a feed's 1200 is ¥1200 and not ¥12. Nothing in this
  // slice special-cases it — `ofMinor` reads the scale off the currency, and for
  // this one the scale is 1.
  test("a currency with no minor unit needs no special case", () =>
    whenInput({
      sku: "p-3",
      title: "ノート",
      desc: "x",
      unitPrice: 1200,
      currency: "JPY",
      category: "cat1",
    })
    ->thenCommand(
      "p-3",
      AddProduct({
        productId: "p-3",
        name: "ノート",
        description: "x",
        price: money(1200.0, JPY),
        categoryId: "cat1",
      }),
    )
  )

  // What "unsupported currency" means now: not a code the domain declined to
  // handle, but one ISO 4217 does not define. The lower-case spelling is the
  // failure the closed type exists to catch, and the feed is told at its first
  // request rather than after a ledger stops adding up.
  test("a code ISO does not define surfaces a translate error", () =>
    whenInput({
      sku: "p-1",
      title: "Laptop",
      desc: "x",
      unitPrice: 1,
      currency: "eur",
      category: "cat1",
    })->thenTranslateError(
      `expected one of the ISO 4217 codes this framework admits (AUD, CAD, CHF, CNY, EUR, GBP, JPY, NOK, SEK, USD), got "eur". Codes are upper-case and exactly three letters.`,
    )
  )

  test("non-positive price surfaces a translate error", () =>
    whenInput({sku: "p-1", title: "Laptop", desc: "x", unitPrice: 0, currency: "USD", category: "cat1"})
    ->thenTranslateError("Price must be positive")
  )

  test("empty SKU surfaces a translate error", () =>
    whenInput({sku: "", title: "Laptop", desc: "x", unitPrice: 100, currency: "USD", category: "cat1"})
    ->thenTranslateError("SKU is required")
  )

  test("empty category surfaces a translate error", () =>
    whenInput({sku: "p-1", title: "Laptop", desc: "x", unitPrice: 100, currency: "USD", category: ""})
    ->thenTranslateError("Category is required")
  )
})
