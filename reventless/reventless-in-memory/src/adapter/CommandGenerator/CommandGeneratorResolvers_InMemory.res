// No-op CommandGenerator resolvers for in-memory (no AppSync).

open ReventlessCore

type api = unit
type runtimeParts = RuntimeEnvironment_InMemory.parts

let handleResolversEvent = (generateCommand: CommandGenerator.commandGenerator) =>
  Pulumi.Output.make((event, _context) => event->generateCommand)

let make: CommandGenerator_Adapter.resolversMaker<unit, runtimeParts> = (
  ~name as _,
  ~api as _,
  ~fields as _,
  ~commandSchema as _,
  ~runtime as _,
  ~resources as _,
  ~opts as _,
) => {resources: []}
