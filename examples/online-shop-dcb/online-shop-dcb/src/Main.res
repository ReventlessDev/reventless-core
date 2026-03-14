// Main entry point — starts an in-memory platform with Catalog + Ordering plugins.
// Run with: npx tsx src/Main.res.mjs

// 1. Activate Pulumi mock mode so Output.apply chains resolve synchronously
let _ = ReventlessInMemory.TestRunner.setup()

// 2. Create the in-memory platform (starts GraphQL server on port 4000)
module Platform = ReventlessInMemory.Platform.MakeWithConfig({
  let silent = false
  let splitApi = true
})

// 3. Apply the two plugin modules to the platform
module Catalog = CatalogPlugin.CatalogPlugin.Make(Platform)
module Ordering = OrderingPlugin.OrderingPlugin.Make(Platform)

// 4. Create a shared scheduler
let scheduler = Platform.makeScheduler()

// 5. Build plugin components — each plugin assembles itself
let catalogPlugin = Catalog.make(~scheduler, ~api=(), ~apiRole=())
let orderingPlugin = Ordering.make(~scheduler, ~api=(), ~apiRole=())

// 6. Build Core (no core-level components for this example)
let core = Platform.Core.make(
  ~version="1.0.0",
  ~extensionPoints=[],
  ~aggregates=[],
  ~readModels=[],
  ~scheduler,
  ~api=(),
  ~apiRole=(),
  ~resourceNaming=ReventlessInMemory.InMemory_PluginSpec.resourceNaming,
)

// 7. Wire everything together
Platform.makePlatform(~api=Obj.magic(), ~core, ~plugins=[catalogPlugin, orderingPlugin])

// 8. Print schema diagnostics when GRAPHQL_DEBUG is set
@val external processEnv: dict<string> = "process.env"
if processEnv->Dict.get("GRAPHQL_DEBUG")->Option.isSome {
  ReventlessInMemory.GraphQL_Server.printDiagnostics()
  switch ReventlessInMemory.Platform.getCoreGraphQL() {
  | Some(core) => core.printDiagnostics()
  | None => ()
  }
}
