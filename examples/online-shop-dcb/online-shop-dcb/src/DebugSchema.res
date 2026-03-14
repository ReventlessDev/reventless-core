// Debug script — boots the in-memory platform with DCB plugins and dumps GraphQL schema info.
//
// Usage:
//   npx rescript && node src/DebugSchema.res.mjs
//
// To keep the server running for GraphiQL exploration:
//   Comment out the GraphQL_Server.stop() line at the bottom,
//   then open http://localhost:4000/graphql in a browser.

module Platform = ReventlessInMemory.Platform.Make()

module Catalog = CatalogPlugin.CatalogPlugin.Make(Platform)
module Ordering = OrderingPlugin.OrderingPlugin.Make(Platform)

Platform.makePlatform(
  ~version="1.0.0",
  ~plugins=[module(Catalog), module(Ordering)],
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
