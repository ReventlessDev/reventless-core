// No-op AppSync CommandGenerator resolver adapter — creates no resolvers.
// Used for admin-internal aggregates (e.g. Plugin) that have real infrastructure
// but no AppSync mutation fields (commands come via the ExtensionPoint, not GraphQL).
type api = Types.AppSync.api
type runtimeParts = Util.Lambda.runtimeParts

let handleResolversEvent = (_generateCommand: ReventlessCore.CommandGenerator.commandGenerator) =>
  Pulumi.Output.make((_event, _context) => Effect.succeed(ReventlessCore.CommandTopic.Pending({msgId: ""})))

let make: ReventlessCore.CommandGenerator_Adapter.resolversMaker<api, runtimeParts> = (
  ~name as _,
  ~api as _,
  ~fields as _,
  ~commandSchema as _,
  ~runtime as _,
  ~resources as _,
  ~opts as _,
) => {
  resources: [],
}
