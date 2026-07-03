// Pins `PluginName` — the single-source plugin-name derivation (plan C3) the
// generator (`Config`) and the gwt graph loader (`LocalHost`) both use. A drift
// here silently breaks graph plugin keys, so these lock the PascalCase mapping
// and the plugin.json → package.json → "Plugin" precedence.

open JestGlobals

module P = PluginName

describe("PluginName.fromPackageName", () => {
  testSync("strips an npm scope and PascalCases the local part", () =>
    expect(P.fromPackageName("@scope/my-catalog"))->toEqual("MyCatalog")
  )
  testSync("PascalCases a dashed unscoped name", () =>
    expect(P.fromPackageName("online-shop"))->toEqual("OnlineShop")
  )
  testSync("splits on underscores as well as dashes", () =>
    expect(P.fromPackageName("online-shop_aggregates-catalog"))->toEqual("OnlineShopAggregatesCatalog")
  )
  testSync("a single lowercase word is capitalised", () =>
    expect(P.fromPackageName("catalog"))->toEqual("Catalog")
  )
})

describe("PluginName.resolve", () => {
  testSync("plugin.json name wins over package.json", () =>
    expect(
      P.resolve(~pluginJsonName=Some("Custom"), ~packageJsonName=Some("online-shop")),
    )->toEqual("Custom")
  )
  testSync("falls back to PascalCase(package.json name) when no plugin.json name", () =>
    expect(P.resolve(~pluginJsonName=None, ~packageJsonName=Some("online-shop")))->toEqual(
      "OnlineShop",
    )
  )
  testSync("falls back to \"Plugin\" when neither is present", () =>
    expect(P.resolve(~pluginJsonName=None, ~packageJsonName=None))->toEqual("Plugin")
  )
})
