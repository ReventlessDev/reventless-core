// Unit tests for LocalHost's pure helpers — plugin-name derivation + discovery.
// These touch only the filesystem (no reventless-local import), so they run under
// the normal Jest suite. The cold-load integration (`loadGraph`, which instantiates
// reventless-local's Platform) can't run under Jest's experimental-vm-modules — see
// tests/SplitApiFixtures.res — and lives in test/LocalHostHostTest.res
// (`pnpm run test:host`, run via `node --test`).
//
// Fixtures are a throwaway temp tree (same pattern as DiscoveryTest) so the test is
// hermetic and doesn't depend on the example plugins being compiled.

open JestGlobals

describe("LocalHost.packageNameToPluginName", () => {
  testPromise("PascalCases scoped / dashed / underscored package names", async () => {
    expect(LocalHost.packageNameToPluginName("@scope/my-catalog"))->toBe("MyCatalog")
    expect(LocalHost.packageNameToPluginName("online-shop"))->toBe("OnlineShop")
    expect(
      LocalHost.packageNameToPluginName("online-shop-aggregates-catalog"),
    )->toBe("OnlineShopAggregatesCatalog")
  })
})

describe("LocalHost name derivation + discovery", () => {
  testPromise(
    "derivePluginName prefers plugin.json then PascalCase(package.json); discover skips non-plugins",
    async () => {
      let root = NodePath.join([NodeOs.tmpdir(), "reventless-localhost-test"])
      let _ = await NodeFs.Promises.rm(root, {recursive: true, force: true})

      // a: explicit plugin.json name + a compiled composition root.
      let a = NodePath.join([root, "a"])
      let aSrc = NodePath.join([a, "src"])
      let _ = await NodeFs.Promises.mkdir(aSrc, {recursive: true})
      let _ =
        await NodeFs.Promises.writeFile(NodePath.join([a, "package.json"]), `{"name":"@x/a-pkg"}`)
      let _ =
        await NodeFs.Promises.writeFile(NodePath.join([aSrc, "plugin.json"]), `{"name":"Catalog"}`)
      let _ = await NodeFs.Promises.writeFile(NodePath.join([aSrc, "Plugin.res.mjs"]), "")

      // b: no plugin.json → name falls back to PascalCase(package.json name).
      let b = NodePath.join([root, "b"])
      let bSrc = NodePath.join([b, "src"])
      let _ = await NodeFs.Promises.mkdir(bSrc, {recursive: true})
      let _ = await NodeFs.Promises.writeFile(
        NodePath.join([b, "package.json"]),
        `{"name":"@scope/my-ordering"}`,
      )
      let _ = await NodeFs.Promises.writeFile(NodePath.join([bSrc, "Plugin.res.mjs"]), "")

      // c: has src/ but no Plugin.res.mjs → discover must skip it.
      let c = NodePath.join([root, "c"])
      let _ = await NodeFs.Promises.mkdir(NodePath.join([c, "src"]), {recursive: true})

      expect(LocalHost.derivePluginName(~pluginSrcDir=aSrc))->toBe("Catalog")
      expect(LocalHost.derivePluginName(~pluginSrcDir=bSrc))->toBe("MyOrdering")

      let refs = LocalHost.discover(~packageDirs=[a, b, c])
      expect(refs->Array.map((r: LocalHost.pluginRef) => r.name))->toEqual(["Catalog", "MyOrdering"])
      let first: LocalHost.pluginRef = refs->Array.getUnsafe(0)
      expect(first.modulePath->String.endsWith("Plugin.res.mjs"))->toBe(true)
      expect(first.packageDir)->toBe(a)

      let _ = await NodeFs.Promises.rm(root, {recursive: true, force: true})
    },
  )
})
