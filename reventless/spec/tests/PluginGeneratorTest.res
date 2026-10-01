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

describe("Codegen.renderMain", () => {
  let main = Codegen.renderMain(
    ~config={
      name: "Catalog",
      heartbeatInterval: 60,
      exclude: [],
      componentRuntime: Dict.make(),
      variant: Config.Aws({compositionNamespace: "CatalogPlugin"}),
    },
  )
  let at = needle => main->String.indexOf(needle)

  // The role check runs while `deployPlugin` builds the plugin, so the pool's
  // groups must be in before it.
  testSync("deploys the plugin once the user pool's groups are in", () =>
    expect(
      at("ReventlessAws.Platform.loadProvidedGroups()->Promise.thenResolve(") > -1 &&
        at("ReventlessAws.Platform.loadProvidedGroups()") < at("Platform.deployPlugin("),
    )->toBe(true)
  )

  // Pulumi `require`s the program; Node refuses that for a top-level await.
  testSync("does not await at the top level", () => expect(at("\nawait "))->toBe(-1))
})
