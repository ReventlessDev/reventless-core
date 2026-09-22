// `InboundTranslation_GWT.Make` expects a single SliceSpec carrying both the
// types (from the spec file) and the `translate` function (from the body
// file). Compose them locally before handing the result to the DSL.

module ImportProductSlice = {
  include ImportProduct
  let translate = ImportProduct_Translation.translate
}

@@reventless.gwt

open CatalogExamples

let pid = CatalogSpec.ProductId.make

// The feed sends minor units already, so these expectations are written the same
// way — `make`, not `ofMajor`. Nothing is scaled at this boundary, which is the
// point: the supplier's `unitPrice` and the domain's `amount` are the same number.

describe("ImportProduct InboundTranslationSlice", () => {
  // scenario-id: 3397fefa-8069-477d-908a-47eff2575d9b
  test("USD payload translates to AddProduct command", () =>
    whenInput({
      sku,
      title: laptop,
      desc: highEnd,
      unitPrice: 99999,
      currency: usd,
      category: categoryRef,
    })->thenCommand(
      "p-1",
      AddProduct({
        productId: pid("p-1"),
        name: laptop,
        description: highEnd,
        price: Reventless.Money.make(~amount=99999.0, ~currency=Reventless.Currency.USD),
        categoryId: cat1,
      }),
    )
  )

  // The case the old translation could not express. It rejected every currency
  // but USD, because the domain had a `float` price and nowhere to record which
  // currency it was in. Now the currency survives, so a second one is ordinary
  // data rather than an unsupported case.
  // scenario-id: d36d7bed-7bc0-44e0-9816-1f4a100371d0
  test("a non-USD payload translates instead of failing", () =>
    whenInput({
      sku: "p-2",
      title: "Buch",
      desc: "gut",
      unitPrice: 1999,
      currency: "EUR",
      category: categoryRef,
    })->thenCommand(
      "p-2",
      AddProduct({
        productId: pid("p-2"),
        name: "Buch",
        description: "gut",
        price: buchPrice,
        categoryId: cat1,
      }),
    )
  )

  // And the case that would have been silently wrong under a hardcoded `/100`:
  // JPY has no minor unit, so ¥1200 is 1200 and not ¥12. Nothing in this slice
  // special-cases it — the amount is simply not scaled at all.
  // scenario-id: d2bd3a34-8613-4b3a-bcac-8f76c2250e4a
  test("a currency with no minor unit needs no special case", () =>
    whenInput({
      sku: "p-3",
      title: "ノート",
      desc: anyDescription,
      unitPrice: 1200,
      currency: "JPY",
      category: categoryRef,
    })->thenCommand(
      "p-3",
      AddProduct({
        productId: pid("p-3"),
        name: "ノート",
        description: anyDescription,
        price: Reventless.Money.make(~amount=1200.0, ~currency=Reventless.Currency.JPY),
        categoryId: cat1,
      }),
    )
  )

  // What "unsupported currency" means now: not a code the domain declined to
  // handle, but one ISO 4217 does not define. The lower-case spelling is the
  // failure the closed type exists to catch, and the feed is told at its first
  // request rather than after a ledger stops adding up.
  // scenario-id: e3bdd07c-c9b1-4a7e-a2b8-a5af1a3a5cc6
  test("a code ISO does not define surfaces a translate error", () =>
    whenInput({
      sku,
      title: laptop,
      desc: anyDescription,
      unitPrice: 1,
      currency: "eur",
      category: categoryRef,
    })->thenTranslateError(`expected one of the ISO 4217 codes this framework admits (AUD, CAD, CHF, CNY, EUR, GBP, JPY, NOK, SEK, USD), got "eur". Codes are upper-case and exactly three letters.`)
  )

  // scenario-id: 7c3755d0-b5d7-4f37-b5d2-e0851da0430e
  test("non-positive price surfaces a translate error", () =>
    whenInput({
      sku,
      title: laptop,
      desc: anyDescription,
      unitPrice: 0,
      currency: usd,
      category: categoryRef,
    })->thenTranslateError("Price must be positive")
  )

  // scenario-id: 8858bf4f-ae25-4b2f-8593-77e4e3333f60
  test("empty SKU surfaces a translate error", () =>
    whenInput({
      sku: "",
      title: laptop,
      desc: anyDescription,
      unitPrice: 100,
      currency: usd,
      category: categoryRef,
    })->thenTranslateError("SKU is required")
  )

  // scenario-id: bfb30209-aa94-4ff5-a4fa-b73011d17ae6
  test("empty category surfaces a translate error", () =>
    whenInput({
      sku,
      title: laptop,
      desc: anyDescription,
      unitPrice: 100,
      currency: usd,
      category: "",
    })->thenTranslateError("Category is required")
  )
})
