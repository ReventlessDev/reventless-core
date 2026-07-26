// `InboundTranslation_GWT.Make` expects a single SliceSpec carrying both the
// types (from the spec file) and the `translate` function (from the body
// file). Compose them locally before handing the result to the DSL.

module ImportProductSlice = {
  include ImportProduct
  let translate = ImportProduct_Translation.translate
}

@@reventless.gwt

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
        price: 999.99,
        imageUrl: "",
        categoryId: "cat1",
      }),
    )
  )

  test("non-USD currency surfaces a translate error", () =>
    whenInput({sku: "p-1", title: "Laptop", desc: "x", unitPrice: 1, currency: "EUR", category: "cat1"})
    ->thenTranslateError("Unsupported currency: EUR")
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
