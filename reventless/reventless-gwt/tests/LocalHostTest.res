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

@module("node:os") external tmpdir: unit => string = "tmpdir"
@module("node:path") external join: (string, string) => string = "join"

type mkdirOpts = {recursive: bool}
@module("node:fs/promises")
external mkdir: (string, mkdirOpts) => promise<Nullable.t<string>> = "mkdir"
@module("node:fs/promises") external writeFile: (string, string) => promise<unit> = "writeFile"
type rmOpts = {recursive: bool, force: bool}
@module("node:fs/promises") external rm: (string, rmOpts) => promise<unit> = "rm"

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
      let root = join(tmpdir(), "reventless-localhost-test")
      let _ = await rm(root, {recursive: true, force: true})

      // a: explicit plugin.json name + a compiled composition root.
      let a = join(root, "a")
      let aSrc = join(a, "src")
      let _ = await mkdir(aSrc, {recursive: true})
      let _ = await writeFile(join(a, "package.json"), `{"name":"@x/a-pkg"}`)
      let _ = await writeFile(join(aSrc, "plugin.json"), `{"name":"Catalog"}`)
      let _ = await writeFile(join(aSrc, "Plugin.res.mjs"), "")

      // b: no plugin.json → name falls back to PascalCase(package.json name).
      let b = join(root, "b")
      let bSrc = join(b, "src")
      let _ = await mkdir(bSrc, {recursive: true})
      let _ = await writeFile(join(b, "package.json"), `{"name":"@scope/my-ordering"}`)
      let _ = await writeFile(join(bSrc, "Plugin.res.mjs"), "")

      // c: has src/ but no Plugin.res.mjs → discover must skip it.
      let c = join(root, "c")
      let _ = await mkdir(join(c, "src"), {recursive: true})

      expect(LocalHost.derivePluginName(~pluginSrcDir=aSrc))->toBe("Catalog")
      expect(LocalHost.derivePluginName(~pluginSrcDir=bSrc))->toBe("MyOrdering")

      let refs = LocalHost.discover(~packageDirs=[a, b, c])
      expect(refs->Array.map((r: LocalHost.pluginRef) => r.name))->toEqual(["Catalog", "MyOrdering"])
      let first: LocalHost.pluginRef = refs->Array.getUnsafe(0)
      expect(first.modulePath->String.endsWith("Plugin.res.mjs"))->toBe(true)
      expect(first.packageDir)->toBe(a)

      let _ = await rm(root, {recursive: true, force: true})
    },
  )
})
