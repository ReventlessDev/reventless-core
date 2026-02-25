// GraphQL mutation resolvers for in-memory CommandGenerator.
// Registers one GraphQL mutation field per resolver config field.
// Uses a module-level pending-handler slot that is populated by handleResolversEvent
// (called via makeHandler) immediately before make() is called via connect().

open Reventless

type api = unit
type runtimeParts = RuntimeEnvironment_InMemory.parts

// -- Pending handler slot --------------------------------------------------
//
// Execution order in Pulumi mock mode (synchronous):
//   1. AggregateRuntime_Builder evaluates ~handler=makeHandler(~publishJsons)
//      -> handleResolversEvent(generateCommand) is called -> pending slot filled
//   2. AggregateRuntime_Builder calls connect(~runtime)
//      -> make() is called -> pending slot consumed; generateCommand captured in closures
//
// This single slot is safe because mock-mode is single-threaded and the two calls
// always happen back-to-back for each aggregate before the next aggregate starts.

let pending: ref<option<CommandGenerator.commandGenerator>> = ref(None)

// -- handleResolversEvent --------------------------------------------------

let handleResolversEvent = (generateCommand: CommandGenerator.commandGenerator) => {
  pending.contents = Some(generateCommand)
  // Return value satisfies the module type; the HTTP resolver path uses generateCommand
  // directly via the closure in make(), not through this Output.
  Pulumi.Output.make((event, _context) => event->generateCommand)
}

// -- make ------------------------------------------------------------------

let make: CommandGenerator_Adapter.resolversMaker<unit, runtimeParts> = (
  ~name as _,
  ~api as _,
  ~fields,
  ~runtime as _,
  ~resources as _,
  ~opts as _,
) => {
  // Consume the pending handler that was set by the preceding handleResolversEvent call.
  let generateCommand = switch pending.contents {
  | Some(fn) =>
    pending.contents = None
    fn
  | None => JsError.throwWithMessage("CommandGeneratorResolvers_GraphQL.make: no pending handler")
  }

  // Build SDL fragment: one field per resolver config entry.
  // Args are generic JSON scalars since concrete types are unknown at schema-build time.
  let sdlFields = fields->Array.map(field => `  ${field}(id: ID, args: String): String`)

  let capitalize = s =>
    s->String.charAt(0)->String.toUpperCase ++ s->String.slice(~start=1)

  let makeResolver = (fieldName: string): GraphQL_Server.resolverFn =>
    async (_root, args) => {
      // Mirror AppSync VTL convention: "aggregate_CommandName" -> "CommandName"
      let commandName = switch fieldName->String.split("_") {
      | [_agg, cmd] => cmd->capitalize
      | _ => fieldName->capitalize
      }
      let payload: CommandGenerator.payload = {
        command: commandName,
        arguments: args->Obj.magic,
        meta: {ip: [], user: "local", info: `Mutation.${fieldName}`},
      }
      let result = await generateCommand(payload)
      result->JSON.Encode.string
    }

  let resolvers = Dict.make()
  fields->Array.forEach(f => resolvers->Dict.set(f, makeResolver(f)))
  GraphQL_Server.registerMutations(~sdlFields, ~resolvers)

  {resources: []}
}
