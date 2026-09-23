open JestGlobals

// `generate-plugin` runs in the `prebuild` of every plugin package, this
// repository's examples and every generated app alike, so the two forms those
// scripts spell are a contract.

describe("PluginGenerator.parseArgs", () => {
  testSync("a plugin's own prebuild: generate-plugin src/", () =>
    expect(PluginGenerator.parseArgs(["src/"]))->toEqual(
      Ok({PluginGenerator.variant: Config.Composition, srcDir: "src/"}),
    )
  )

  testSync("an -aws package's prebuild: generate-plugin --aws <Namespace> <srcDir>", () =>
    expect(PluginGenerator.parseArgs(["--aws", "CatalogPlugin", "../catalog/src/"]))->toEqual(
      Ok({
        PluginGenerator.variant: Config.Aws({compositionNamespace: "CatalogPlugin"}),
        srcDir: "../catalog/src/",
      }),
    )
  )

  testSync("no source directory is refused", () =>
    expect(PluginGenerator.parseArgs([])->Result.isError)->toBe(true)
  )

  testSync("--aws without its source directory is refused", () =>
    expect(PluginGenerator.parseArgs(["--aws", "CatalogPlugin"])->Result.isError)->toBe(true)
  )
})
