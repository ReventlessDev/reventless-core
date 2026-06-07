// Integration test for LocalHost.loadGraph — the cold-load path that instantiates
// reventless-local's Platform and builds the real example plugins against it.
//
// Runs under `node --test` (NOT Jest) on purpose: cold-loading the local platform
// under Jest's experimental-vm-modules hits the graphql/yoga CJS-in-ESM interop
// wall documented in tests/SplitApiFixtures.res. Plain node ESM is exactly the
// runtime the CLI host uses, and where the Phase 4.5 spike proved cold-load works
// (docs/analysis/reventless-vscode-domain-graph-design.md "Spike result"). It is
// named without the `Test` suffix so the Jest `testMatch` glob
// (`tests/**/*Test.res.mjs`) skips it — `pnpm run test:host` runs it via node. The
// pure helpers (name derivation, discovery) are the Jest test in tests/LocalHostTest.res.
//
// Prerequisite: reventless-local + the online-shop-aggregates examples must be
// compiled (`pnpm run build` at the repo root). Run: `pnpm run test:host`.

@module("node:test") external test: (string, unit => promise<unit>) => unit = "test"
@module("node:assert/strict") external equal: ('a, 'a) => unit = "equal"
@module("node:assert/strict") external deepEqual: ('a, 'a) => unit = "deepEqual"
@module("node:assert/strict") external ok: (bool, ~message: string=?) => unit = "ok"

@module("node:url") external fileURLToPath: string => string = "fileURLToPath"
@module("node:path") external dirname: string => string = "dirname"
@module("node:path") @variadic external join: array<string> => string = "join"

let here = dirname(fileURLToPath(%raw(`import.meta.url`)))
let repoRoot = join([here, "..", "..", ".."]) // reventless-gwt/test → repo root
let catalogDir = join([repoRoot, "examples", "online-shop-aggregates", "catalog"])
let orderingDir = join([repoRoot, "examples", "online-shop-aggregates", "ordering"])
let platformPath = join([repoRoot, "reventless", "reventless-local", "src", "Platform.res.mjs"])

let structureFor = (g: LocalHost.graph, name) =>
  g.structures->Array.find(((n, _)) => n == name)->Option.map(((_, s)) => s)

let edgeKey = (e: Reventless.Plugin.graphEdge) =>
  `${e.mechanism}:${e.source.pluginName}.${e.source.componentName}->${e.target.pluginName}.${e.target.componentName}`

test("loadGraph cold-loads structures + cross-plugin edges from the real plugins", async () => {
  let plugins = LocalHost.discover(~packageDirs=[catalogDir, orderingDir])
  let g = await LocalHost.loadGraph(~platformModulePath=platformPath, ~plugins)

  // structures: resolved plain records, plugin-namespaced event types.
  deepEqual(g.structures->Array.map(((n, _)) => n), ["Catalog", "Ordering"])

  let catalog = structureFor(g, "Catalog")->Option.getOrThrow
  let category = catalog.aggregates->Array.find((a: Reventless.Plugin.writableDef) => a.name == "Category")->Option.getOrThrow
  ok(category.producedEventTypes->Array.includes("Catalog.Added"))

  let ordering = structureFor(g, "Ordering")->Option.getOrThrow
  let order = ordering.aggregates->Array.find((a: Reventless.Plugin.writableDef) => a.name == "Order")->Option.getOrThrow
  ok(order.producedEventTypes->Array.includes("Ordering.Placed"))

  // extensionPoints (producer side): Catalog owns Catalog.Products, fed by the
  // Product aggregate's internal events — so the EP's sourceEventTypes are a
  // subset of the producer's producedEventTypes, the link the event graph draws.
  let catalogEps = catalog.extensionPoints->Option.getOr([])
  let productsEp =
    catalogEps->Array.find((e: Reventless.Plugin.extensionPointDef) => e.name == "Catalog.Products")->Option.getOrThrow
  ok(productsEp.delegateNames->Array.includes("Product"), ~message=productsEp.delegateNames->Array.join(","))
  ok(
    productsEp.sourceEventTypes->Array.includes("Catalog.Added"),
    ~message=productsEp.sourceEventTypes->Array.join(","),
  )
  let product = catalog.aggregates->Array.find((a: Reventless.Plugin.writableDef) => a.name == "Product")->Option.getOrThrow
  ok(productsEp.sourceEventTypes->Array.every(e => product.producedEventTypes->Array.includes(e)))

  // edges: the two bidirectional Extension↔ExtensionPoint links.
  let keys = g.edges->Array.map(edgeKey)
  ok(
    keys->Array.includes("Extension:Ordering.Ordering.Orders->Catalog.Ordering.Orders"),
    ~message=keys->Array.join(" | "),
  )
  ok(
    keys->Array.includes("Extension:Catalog.Catalog.Products->Ordering.Catalog.Products"),
    ~message=keys->Array.join(" | "),
  )
})

test("loadGraph is cold — a second call in the same process succeeds (cache-busting works)", async () => {
  let plugins = LocalHost.discover(~packageDirs=[catalogDir])
  let g1 = await LocalHost.loadGraph(~platformModulePath=platformPath, ~plugins)
  let g2 = await LocalHost.loadGraph(~platformModulePath=platformPath, ~plugins)
  equal(g1.structures->Array.length, 1)
  equal(g2.structures->Array.length, 1)
})
