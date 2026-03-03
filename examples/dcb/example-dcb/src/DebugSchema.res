// Debug script — boots the in-memory platform with DCB plugins and dumps GraphQL schema info.
//
// Usage:
//   npx rescript && node src/DebugSchema.res.mjs
//
// To keep the server running for GraphiQL exploration:
//   Comment out the GraphQL_Server.stop() line at the bottom,
//   then open http://localhost:4000/graphql in a browser.

// 1. Activate Pulumi mock mode
let _ = ReventlessInMemory.TestRunner.setup()

// 2. Create the in-memory platform (starts GraphQL server on port 4000)
module Platform = ReventlessInMemory.Platform.Make()

// 3. Apply the two plugin modules to the platform
module Catalog = ReventlessdevExampleDcbCatalog.CatalogPlugin.Make(Platform)
module Ordering = ReventlessdevExampleDcbOrdering.OrderingPlugin.Make(Platform)

// 4. Create a shared scheduler
let scheduler = Platform.makeScheduler()

// 5. Build plugin components
let _catalogPlugin = Catalog.make(~scheduler, ~api=(), ~apiRole=())
let _orderingPlugin = Ordering.make(~scheduler, ~api=(), ~apiRole=())

// 6. Build Core
let _core = Platform.Core.make(
  ~version="1.0.0",
  ~extensionPoints=[],
  ~aggregates=[],
  ~readModels=[],
  ~scheduler,
  ~api=(),
  ~apiRole=(),
  ~resourceNaming=ReventlessInMemory.InMemory_PluginSpec.resourceNaming,
)

// --- Schema diagnostics ---

Console.log("\n========================================")
Console.log("  GraphQL Schema Diagnostics")
Console.log("========================================\n")

// Print the live SDL from the validated schema object
ReventlessInMemory.GraphQL_Server.printLiveSdl()

Console.log("")

// Print full diagnostics (resolver/SDL mismatches, counts, etc.)
ReventlessInMemory.GraphQL_Server.printDiagnostics()

// Stop the server so the script exits cleanly
ReventlessInMemory.GraphQL_Server.stop()
