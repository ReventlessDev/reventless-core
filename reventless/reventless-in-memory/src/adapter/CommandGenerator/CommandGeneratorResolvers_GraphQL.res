// GraphQL mutation resolvers for in-memory CommandGenerator.
//
// Two-phase registration for both Aggregate and DCB StateChangeSlice mutations:
//   Phase 1 (synchronous): Plugin_Builder/Dcb_Builder calls register/registerDcb via hooks
//     during construct(). This registers SDL fields and resolver stubs in GraphQL_Server
//     immediately — before Output.apply chains fire.
//   Phase 2 (async, inside Output.apply):
//     - Aggregates: AggregateRuntime_Builder calls handleResolversEvent then make().
//     - DCB: Dcb_Builder calls bindHandler() directly.

@@warning("-44")
open ReventlessCore

type api = unit
type runtimeParts = RuntimeEnvironment_InMemory.parts

// -- Identity extraction from GraphQL context ---------------------------------
// graphql-yoga provides { request: Request, ... } as the resolver context.
// We read the X-Identity header (JSON-encoded Identity.t) and fall back to anonymous.

@send external getHeader: ('headers, string) => Nullable.t<string> = "get"

let extractIdentity = (ctx: JSON.t): Reventless.Identity.t => {
  try {
    let request = (ctx->Obj.magic)["request"]
    let headers = request["headers"]
    switch headers->getHeader("x-identity")->Nullable.toOption {
    | Some(json) => json->JSON.parseOrThrow->S.parseOrThrow(Reventless.Identity.schema)
    | None => Reventless.Identity.anonymous
    }
  } catch {
  | _ => Reventless.Identity.anonymous
  }
}

let capitalize = s =>
  s->String.charAt(0)->String.toUpperCase ++ s->String.slice(~start=1)

// -- CommandResult SDL types --------------------------------------------------
// Registered once per server (guards against duplicate registration after reset).

let commandResultSdl = `union CommandResult = CommandAccepted | CommandRejected | CommandPending

type CommandAccepted {
  msgId: ID!
  entityId: ID
  eventCount: Int!
}

type CommandRejected {
  msgId: ID!
  errorCode: String!
  errorDetail: String
}

type CommandPending {
  msgId: ID!
}`

let ensureCommandResultTypes = (server: GraphQL_ServerInstance.t) => {
  if !(server.buildSdl()->String.includes("CommandAccepted")) {
    server.registerTypes(~sdlTypes=[commandResultSdl])
  }
}

let commandOutcomeToJson = (outcome: ReventlessCore.CommandTopic.commandOutcome): JSON.t =>
  switch outcome {
  | Accepted({msgId, eventCount} as accepted) =>
    JSON.Object(
      Dict.fromArray([
        ("__typename", JSON.String("CommandAccepted")),
        ("msgId", JSON.String(msgId)),
        ("entityId", accepted.entityId->Option.map(id => JSON.String(id))->Option.getOr(JSON.Null)),
        ("eventCount", JSON.Number(eventCount->Int.toFloat)),
      ]),
    )
  | Rejected({msgId, errorCode, errorDetail}) =>
    JSON.Object(
      Dict.fromArray([
        ("__typename", JSON.String("CommandRejected")),
        ("msgId", JSON.String(msgId)),
        ("errorCode", JSON.String(errorCode)),
        ("errorDetail", errorDetail->Option.map(s => JSON.String(s))->Option.getOr(JSON.Null)),
      ]),
    )
  | Pending({msgId}) =>
    JSON.Object(
      Dict.fromArray([
        ("__typename", JSON.String("CommandPending")),
        ("msgId", JSON.String(msgId)),
      ]),
    )
  }

let extractCommandName = (fieldName: string) => {
  let parts = fieldName->String.split("_")
  parts->Array.get(parts->Array.length - 1)->Option.getOr(fieldName)->capitalize
}

// -- Shared SDL derivation helpers --------------------------------------------

let extractVariantSchema = (commandSchema: S.t<unknown>, ~index=0) =>
  switch commandSchema {
  | Union({anyOf}) => anyOf->Array.get(index)->Option.getOr(commandSchema)
  | _ => commandSchema
  }

let deriveSdlField = (~fieldName, variantSchema: S.t<unknown>) =>
  switch GraphQL_FragmentGenerator.deriveMutationFieldFromObject(~fieldName, variantSchema) {
  | Some(field) =>
    // deriveMutationFieldFromObject always ends with ": String!" as the return type.
    // Replace only the trailing suffix — NOT the first occurrence, which would corrupt
    // String argument types (e.g. `name: String!` → `name: CommandResult!`).
    let returnTypeSuffix = ": String!"
    let n = field->String.length - returnTypeSuffix->String.length
    field->String.slice(~start=0, ~end=n) ++ ": CommandResult!"
  | None => `  ${fieldName}: CommandResult!`
  }

// -- Per-field handler refs ---------------------------------------------------
// Populated by register()/registerDcb() with empty refs; bound by make() or
// bindHandler() when generateCommand becomes available.

let handlerRefs: dict<ref<option<CommandGenerator.commandGenerator>>> = Dict.make()

// -- register (Phase 1 — synchronous, Aggregates) ----------------------------
// Called by Plugin_Builder via aggregateMutationResolverHook before any
// Output.apply chains fire. Registers SDL + resolver stubs in GraphQL_Server.

let register = (~fields: array<string>, ~commandSchema: S.t<unknown>, ~server: GraphQL_ServerInstance.t) => {
  ensureCommandResultTypes(server)
  // Aggregate commands target a specific instance — prepend id: ID!
  let sdlFields = fields->Array.mapWithIndex((field, i) => {
    let sdl = deriveSdlField(~fieldName=field, extractVariantSchema(commandSchema, ~index=i))
    if sdl->String.includes("(") {
      sdl->String.replace(`${field}(`, `${field}(id: ID!, `)
    } else {
      sdl->String.replace(`${field}:`, `${field}(id: ID!):`)
    }
  })

  let resolvers = Dict.make()
  fields->Array.forEach(field => {
    let handlerRef = ref(None)
    handlerRefs->Dict.set(field, handlerRef)
    let resolver: GraphQL_ServerInstance.resolverFn = async (_root, args, ctx) => {
      switch handlerRef.contents {
      | Some(generateCommand) =>
        let identity = extractIdentity(ctx)
        let commandName = extractCommandName(field)
        let payload: CommandGenerator.payload = {
          command: commandName,
          arguments: args->Obj.magic,
          meta: {ip: [], user: identity.userId, info: `Mutation.${field}`},
          identity,
        }
        let outcome = await generateCommand(payload)->Effect.runPromise
        outcome->commandOutcomeToJson
      | None => JSON.Encode.null
      }
    }
    resolvers->Dict.set(field, resolver)
  })

  server.registerMutations(~sdlFields, ~resolvers)
}

// -- registerDcb (Phase 1 — synchronous, DCB StateChangeSlices) ---------------
// Called by Dcb_Builder via dcbMutationResolverHook. Registers SDL + resolver
// stubs for DCB mutations. Unlike aggregate mutations, DCB commands use a tagged
// ID field (e.g., itemId) instead of a separate id: ID! parameter.

let registerDcb = (~fieldName: string, ~commandSchema: S.t<unknown>, ~server: GraphQL_ServerInstance.t) => {
  ensureCommandResultTypes(server)
  let variantSchema = extractVariantSchema(commandSchema)
  let sdlFields = [deriveSdlField(~fieldName, variantSchema)]

  // Extract TAG (variant constructor name) for routing
  let constructorNames = Reventless.DcbTag.extractEventTypes(commandSchema->Obj.magic)
  let tag = constructorNames->Array.get(0)->Option.getOr(fieldName)

  // Find the tagged ID field name (the one with @s.matches(DcbTag.string))
  let idFieldName = switch variantSchema {
  | Object({properties}) =>
    properties
    ->Dict.toArray
    ->Array.findMap(((name, fieldSchema)) =>
      if Reventless.DcbTag.isTagged(fieldSchema) {
        Some(name)
      } else {
        None
      }
    )
  | _ => None
  }

  let handlerRef = ref(None)
  handlerRefs->Dict.set(fieldName, handlerRef)

  let resolver: GraphQL_ServerInstance.resolverFn = async (_root, args, ctx) => {
    switch handlerRef.contents {
    | Some(generateCommand) =>
      let identity = extractIdentity(ctx)
      let argsDict: dict<JSON.t> = args->Obj.magic

      // Extract entity ID from tagged field and add as "id" for generateCommand.
      // Skip if the tagged field is already called "id" (it's already present).
      switch idFieldName {
      | Some(idField) if idField != "id" =>
        let id = switch argsDict->Dict.get(idField) {
        | Some(JSON.String(s)) => s
        | _ => ""
        }
        argsDict->Dict.set("id", JSON.Encode.string(id))
      | _ => ()
      }

      let payload: CommandGenerator.payload = {
        command: tag,
        arguments: argsDict->Obj.magic,
        meta: {ip: [], user: identity.userId, info: `Mutation.${fieldName}`},
        identity,
      }
      let outcome = await generateCommand(payload)->Effect.runPromise
      outcome->commandOutcomeToJson
    | None => JSON.Encode.null
    }
  }

  let resolvers = Dict.make()
  resolvers->Dict.set(fieldName, resolver)
  server.registerMutations(~sdlFields, ~resolvers)
}

// -- bindHandler (Phase 2 — direct binding) -----------------------------------
// Binds a generateCommand function to a pre-registered resolver stub.
// Used by DCB StateChangeSlices via dcbMutationBindHook.

let bindHandler = (~field: string, ~generateCommand: CommandGenerator.commandGenerator) => {
  switch handlerRefs->Dict.get(field) {
  | Some(handlerRef) => handlerRef.contents = Some(generateCommand)
  | None => ()
  }
}

// -- Pending handler slot (Phase 2, Aggregates) -------------------------------

let pending: ref<option<CommandGenerator.commandGenerator>> = ref(None)

let handleResolversEvent = (generateCommand: CommandGenerator.commandGenerator) => {
  pending.contents = Some(generateCommand)
  Pulumi.Output.make((event, _context) => event->generateCommand)
}

// -- make (Phase 2 — inside Output.apply, Aggregates) -------------------------
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
