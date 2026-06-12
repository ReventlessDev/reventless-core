// Unit tests for ComponentMeta — the pure folder-convention → {kind, name}
// derivation behind the `component` field on file items and the `components`
// inventory. No I/O; path strings only.

open JestGlobals

describe("ComponentMeta.componentOfTestFile", () => {
  testPromise("derives kind + name from a slice GWT test path", async () => {
    let c = ComponentMeta.componentOfTestFile(
      "/repo/catalog/tests/Product/StateChangeSlice/AddProduct_GWT.res.mjs",
    )
    expect(c)->toEqual(Some({ComponentMeta.kind: "StateChangeSlice", name: "AddProduct"}))
  })

  testPromise("derives a ReadModel component", async () => {
    let c = ComponentMeta.componentOfTestFile(
      "/repo/catalog/tests/CatalogActivity/ReadModel/CatalogActivity_GWT.res.mjs",
    )
    expect(c)->toEqual(Some({ComponentMeta.kind: "ReadModel", name: "CatalogActivity"}))
  })

  testPromise("strips the GwtTest marker shape too", async () => {
    let c = ComponentMeta.componentOfTestFile("/repo/x/tests/Order/Aggregate/OrderGwtTest.res.mjs")
    expect(c)->toEqual(Some({ComponentMeta.kind: "Aggregate", name: "Order"}))
  })

  testPromise("returns None outside a recognised kind folder", async () => {
    let c = ComponentMeta.componentOfTestFile("/repo/x/tests/Helpers/Thing_GWT.res.mjs")
    expect(c)->toEqual(None)
  })
})

describe("ComponentMeta.componentOfSrcFile", () => {
  testPromise("collapses a spec file to its component", async () => {
    let c = ComponentMeta.componentOfSrcFile("/repo/catalog/src/Product/Aggregate/Product.res")
    expect(c)->toEqual(Some({ComponentMeta.kind: "Aggregate", name: "Product"}))
  })

  testPromise("collapses a behavior body file to the same component", async () => {
    let c = ComponentMeta.componentOfSrcFile(
      "/repo/catalog/src/Product/Aggregate/Product_Behavior.res",
    )
    expect(c)->toEqual(Some({ComponentMeta.kind: "Aggregate", name: "Product"}))
  })

  testPromise("strips the longest body suffix first (ExtensionPointMapping)", async () => {
    let c = ComponentMeta.componentOfSrcFile(
      "/repo/catalog/src/Products/ExtensionPoint/Products_ExtensionPointMapping.res",
    )
    expect(c)->toEqual(Some({ComponentMeta.kind: "ExtensionPoint", name: "Products"}))
  })
})
