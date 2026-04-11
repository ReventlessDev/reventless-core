// Platform (admin-facing) in-memory MCP server — singleton.
// Serves admin/core operations on a separate port in split mode (port 3002).
//
// Uses the MCP_ServerInstance factory with a "MCP:Platform" label so log
// output is distinguishable from the domain MCP server.

let instance: MCP_ServerInstance.t = MCP_ServerInstance.make(~label="MCP:Platform")

// Re-export all instance functions for module-style access.
let registerTool = instance.registerTool
let registerResource = instance.registerResource
let registerResourceTemplate = instance.registerResourceTemplate
let registerToolsFromEntries = instance.registerToolsFromEntries
let registerResourcesFromEntries = instance.registerResourcesFromEntries
let registerEventHistoryResourcesFromEntries = instance.registerEventHistoryResourcesFromEntries
let start = instance.start
let stop = instance.stop
let reset = instance.reset
let diagnostics = instance.diagnostics
let printDiagnostics = instance.printDiagnostics

// Expose as MCP_ServerInstance.t for resolveTargetMCP() in Platform.res.
let asInterface: MCP_ServerInstance.t = instance
