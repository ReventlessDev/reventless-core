// `InboundTranslation_GWT.Make` expects a single SliceSpec carrying both the
// types (from the spec file) and the `translate` function (from the body
// file). The split-form production layout doesn't expose them as one module,
// so we compose them locally before handing the result to the DSL.

module ImportProductSlice = {
  include ImportProduct
  let translate = ImportProduct_Translation.translate
}

@@reventless.gwt

open Catalog_Examples

let pid = CatalogSpec.ProductId.make

describe("ImportProduct InboundTranslationSlice", () => {
  // scenario-id: 4cbadb5a-5e07-4fc0-8f10-ce2ded113f3b
  test("USD payload translates to AddProduct command", () =>
    whenInput({
      sku,
      title: laptop,
      desc: highEnd,
      unitPrice: 99999,
      currency: usd,
    })->thenCommand(
      "p-1",
      AddProduct({productId: pid("p-1"), name: laptop, description: highEnd, price: 999.99}),
    )
  )

  // scenario-id: 4f28c7af-d7bf-4173-9d96-f71e718dfa80
  test("non-USD currency surfaces a translate error", () =>
    whenInput({
      sku,
      title: laptop,
      desc: anyDescription,
      unitPrice: 1,
      currency: "EUR",
    })->thenTranslateError("Unsupported currency: EUR")
  )

  // scenario-id: 30392a34-8a08-4ec1-98ed-c866076d428e
  test("non-positive price surfaces a translate error", () =>
    whenInput({
      sku,
      title: laptop,
      desc: anyDescription,
      unitPrice: 0,
      currency: usd,
    })->thenTranslateError("Price must be positive")
  )

  // scenario-id: 023bea5d-de52-462b-bc42-70a3e95d72ce
  test("empty SKU surfaces a translate error", () =>
    whenInput({
      sku: "",
      title: laptop,
      desc: anyDescription,
      unitPrice: 100,
      currency: usd,
    })->thenTranslateError("SKU is required")
  )
})
