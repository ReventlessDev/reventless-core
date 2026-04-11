// Platform (admin-facing) in-memory GraphQL server — singleton.
// Serves admin/core operations on a separate port in split mode (port 4001).
//
// Uses the same GraphQL_ServerInstance factory as the generic instance,
// but is exposed as a named singleton so Platform.res can reference it
// directly (mirroring the AWS PlatformAPI resource pattern).
//
// Does NOT include Relay-specific features (encodeGlobalId, node resolver)
// since admin queries are not Relay-paginated.

let instance: GraphQL_ServerInstance.t = GraphQL_ServerInstance.make(~label="GraphQL:Platform")

// Re-export all instance functions for module-style access.
let registerMutations = instance.registerMutations
let registerQueries = instance.registerQueries
let registerTypes = instance.registerTypes
let getMutationResolver = instance.getMutationResolver
let getQueryResolver = instance.getQueryResolver
let start = instance.start
let stop = instance.stop
let reset = instance.reset
let buildSdl = instance.buildSdl
let getFullSdl = instance.getFullSdl
let getSchema = instance.getSchema
let diagnostics = instance.diagnostics
let printDiagnostics = instance.printDiagnostics

// Expose as GraphQL_ServerInstance.t for resolveTargetGraphQL() in Platform.res.
let asInterface: GraphQL_ServerInstance.t = instance
