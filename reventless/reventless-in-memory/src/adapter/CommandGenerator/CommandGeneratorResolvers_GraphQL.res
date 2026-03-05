// GraphQL mutation resolvers for in-memory CommandGenerator.
//
// Two-phase registration:
//   Phase 1 (synchronous): Plugin_Builder calls `register(~fields, ~commandSchema)` via the
//     aggregateMutationResolverHook during construct(). This registers SDL fields and resolver
//     stubs in GraphQL_Server immediately — before Output.apply chains fire.
//   Phase 2 (async, inside Output.apply): AggregateRuntime_Builder calls handleResolversEvent
//     then make(). make() binds the real generateCommand function to the resolver stubs.

open ReventlessCore

type api = unit
type runtimeParts = RuntimeEnvironment_InMemory.parts

let capitalize = s =>
  s->String.charAt(0)->String.toUpperCase ++ s->String.slice(~start=1)

let extractCommandName = (fieldName: string) => {
  let parts = fieldName->String.split("_")
  parts->Array.get(parts->Array.length - 1)->Option.getOr(fieldName)->capitalize
}

// -- Per-field handler refs ---------------------------------------------------
// Populated by register() with empty refs; bound by make() when generateCommand
// becomes available.

let handlerRefs: dict<ref<option<CommandGenerator.commandGenerator>>> = Dict.make()

// -- register (Phase 1 — synchronous) ----------------------------------------
// Called by Plugin_Builder via aggregateMutationResolverHook before any
// Output.apply chains fire. Registers SDL + resolver stubs in GraphQL_Server.

let register = (~fields: array<string>, ~commandSchema: S.t<unknown>) => {
  let anyOf = switch commandSchema {
  | Union({anyOf}) => anyOf
  | _ => []
  }

  // Aggregate commands target a specific instance — prepend id: ID!
  let sdlFields = fields->Array.mapWithIndex((field, i) => {
    let variantSchema = anyOf->Array.get(i)->Option.getOr(commandSchema)
    switch GraphQL_FragmentGenerator.deriveMutationFieldFromObject(
      ~fieldName=field,
      variantSchema,
      ~authorization=None,
    ) {
    | Some(sdl) =>
      if sdl->String.includes("(") {
        sdl->String.replace(`${field}(`, `${field}(id: ID!, `)
      } else {
        sdl->String.replace(`${field}:`, `${field}(id: ID!):`)
      }
    | None => `  ${field}(id: ID!): String!`
    }
  })

  let resolvers = Dict.make()
  fields->Array.forEach(field => {
    let handlerRef = ref(None)
    handlerRefs->Dict.set(field, handlerRef)
    let resolver: GraphQL_Server.resolverFn = async (_root, args) => {
      switch handlerRef.contents {
      | Some(generateCommand) =>
        let commandName = extractCommandName(field)
        let payload: CommandGenerator.payload = {
          command: commandName,
          arguments: args->Obj.magic,
          meta: {ip: [], user: "local", info: `Mutation.${field}`},
        }
        let result = await generateCommand(payload)->Effect.runPromise
        result->JSON.Encode.string
      | None => JSON.Encode.null
      }
    }
    resolvers->Dict.set(field, resolver)
  })

  GraphQL_Server.registerMutations(~sdlFields, ~resolvers)
}

// -- Pending handler slot (Phase 2) -------------------------------------------

let pending: ref<option<CommandGenerator.commandGenerator>> = ref(None)

let handleResolversEvent = (generateCommand: CommandGenerator.commandGenerator) => {
  pending.contents = Some(generateCommand)
  Pulumi.Output.make((event, _context) => event->generateCommand)
}

// -- make (Phase 2 — inside Output.apply) -------------------------------------
// Binds the real generateCommand to resolver stubs created by register().

let make: CommandGenerator_Adapter.resolversMaker<unit, runtimeParts> = (
  ~name as _,
  ~api as _,
  ~fields,
  ~commandSchema as _,
  ~runtime as _,
  ~resources as _,
  ~opts as _,
) => {
  let generateCommand = switch pending.contents {
  | Some(fn) =>
    pending.contents = None
    fn
  | None => JsError.throwWithMessage("CommandGeneratorResolvers_GraphQL.make: no pending handler")
  }

  // Bind generateCommand to the pre-registered resolver stubs
  fields->Array.forEach(field => {
    switch handlerRefs->Dict.get(field) {
    | Some(handlerRef) => handlerRef.contents = Some(generateCommand)
    | None => ()
    }
  })

  {resources: []}
}
