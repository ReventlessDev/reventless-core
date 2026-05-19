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
// graphql-yoga's `context` factory in DomainGraphQL_Server.buildAuthContext
// runs Auth_InMemory.authenticate per request and attaches the resolved
// `Identity.t` to `ctx.identity`. Resolvers read it from there; fallback to
// anonymous only when ctx is malformed.

let extractIdentity = (ctx: JSON.t): Reventless.Identity.t => {
  try {
    switch (ctx->Obj.magic)["identity"]->Nullable.toOption {
    | Some(id) => (id: Reventless.Identity.t)
    | None => Reventless.Identity.anonymous
    }
  } catch {
  | _ => Reventless.Identity.anonymous
  }
}

// -- Authorization rejection --------------------------------------------------
// Returns a `CommandRejected` outcome with a fresh msgId so the GraphQL union
// resolves consistently — matches the existing CommandResult contract.

let rejectForbidden = (~field: string): JSON.t =>
  JSON.Object(
    Dict.fromArray([
      ("__typename", JSON.String("CommandRejected")),
      ("msgId", JSON.String(ReventlessCore.Message.uuid())),
      ("errorCode", JSON.String("Forbidden")),
      ("errorDetail", JSON.String(`Mutation.${field}: identity is not authorized`)),
    ]),
  )

// -- Plugin status gate -------------------------------------------------------
// Set by the platform after Admin.construct to wire a per-mutation lookup against
// the Plugin read model. Takes a mutation field name (e.g. "Catalog_Product_Add"),
// returns `Some((errorCode, errorDetail))` if the mutation should be rejected,
// or `None` otherwise. Platform_* admin mutations are exempt — the gate function
// should return None for them. The error code distinguishes the two off-tiers
// from `docs/analysis/plugin-lifecycle-tiers.md`:
//   - `PluginUnavailable` — tier 1 (Disconnected); retryable.
//   - `PluginInactive`    — tier 2 (Inactive);     admin-controlled, do not retry.
// Wrapping a ref instead of a functor argument keeps the module callable as-is
// from existing call sites.

let pluginStatusGate: ref<option<string => option<(string, string)>>> = ref(None)
let setPluginStatusGate = fn => pluginStatusGate := Some(fn)
let resetPluginStatusGate = () => pluginStatusGate := None

let rejectPluginStatus = (~field: string, ~errorCode: string, ~detail: string): JSON.t =>
  JSON.Object(
    Dict.fromArray([
      ("__typename", JSON.String("CommandRejected")),
      ("msgId", JSON.String(ReventlessCore.Message.uuid())),
      ("errorCode", JSON.String(errorCode)),
      ("errorDetail", JSON.String(`Mutation.${field}: ${detail}`)),
    ]),
  )

let checkPluginStatus = (~field: string): option<JSON.t> =>
  switch pluginStatusGate.contents {
  | Some(gate) =>
    switch gate(field) {
    | Some((errorCode, detail)) => Some(rejectPluginStatus(~field, ~errorCode, ~detail))
    | None => None
    }
  | None => None
  }

// Build a synthetic command value sufficient for evaluating
// `commandAuthorization`. ReScript variants with record payloads compile to
// `{TAG: cname, ...payload}` and the PPX-generated switch matches `Ctor(_)`
// which only checks `command.TAG === cname`. Payload-less constructors
// compile to bare string literals and the switch matches them with
// `command === "Cname"`, so the synthetic value must be a bare string in
// that case — otherwise the wildcard branch (file-level default) wins
// instead of the per-constructor rule.
let syntheticCommand = (cname: string, ~hasPayload: bool): unknown =>
  hasPayload ? {"TAG": cname}->Obj.magic : cname->Obj.magic

let capitalize = s =>
  s->String.charAt(0)->String.toUpperCase ++ s->String.slice(~start=1)

// -- CommandResult SDL types --------------------------------------------------
// Source of truth lives in GraphQL_FragmentGenerator.commandResultSdlTypes so
// the AWS stitched schema and the in-memory graphql-yoga server agree on the
// CommandResult shape. We join the 4 declarations into a single SDL block for
// the in-memory server's registerTypes API.
// Registered once per server (guards against duplicate registration after reset).

let commandResultSdl = GraphQL_FragmentGenerator.commandResultSdlTypes->Array.join("\n\n")

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

// Find the variant index in commandSchema that matches the constructor name
// extracted from `field` (e.g. `Platform_Plugin_Activate` → `Activate`). When
// the auto-flow filters @noApi variants out of `fields` but passes the
// unfiltered commandSchema, position-based lookup mismatches names against
// variant payloads — e.g. it would marry the `Platform_Plugin_Deactivate`
// field name to the `Connect(pluginDefinition)` variant schema, leaking a
// stale `_0` payload arg into the SDL. Looking up by name avoids that.
let variantIndexForField = (commandSchema: S.t<unknown>, ~field: string): int => {
  let cname = extractCommandName(field)
  let allNames = Reventless.DcbTag.extractAllVariantNames(commandSchema->Obj.magic)
  allNames->Array.indexOf(cname)
}

let deriveSdlField = (~fieldName, variantSchema: S.t<unknown>) =>
  switch GraphQL_FragmentGenerator.deriveMutationFieldFromObject(
    ~fieldName,
    ~collectedTypes=[],
    ~seenTypes=Set.make(),
    variantSchema,
  ) {
  | Some(field) => field
  | None => `  ${fieldName}: CommandResult!`
  }

// -- Per-field handler refs ---------------------------------------------------
// Populated by register()/registerDcb() with empty refs; bound by make() or
// bindHandler() when generateCommand becomes available.

let handlerRefs: dict<ref<option<CommandGenerator.commandGenerator>>> = Dict.make()

// -- register (Phase 1 — synchronous, Aggregates) ----------------------------
// Called by Plugin_Builder via aggregateMutationResolverHook before any
// Output.apply chains fire. Registers SDL + resolver stubs in GraphQL_Server.

let register = (
  ~fields: array<string>,
  ~commandSchema: S.t<unknown>,
  ~commandAuthorization: unknown => Reventless.Authorization.permission,
  ~server: GraphQL_ServerInstance.t,
) => {
  ensureCommandResultTypes(server)
  // Aggregate commands target a specific instance — prepend id: ID!
  let sdlFields = fields->Array.map(field => {
    let variantIndex = variantIndexForField(commandSchema, ~field)
    let sdl = deriveSdlField(~fieldName=field, extractVariantSchema(commandSchema, ~index=variantIndex))
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
    // hasPayload is fixed per field — capture once at registration time so
    // the resolver doesn't re-walk the schema per request.
    let variantIndex = variantIndexForField(commandSchema, ~field)
    let hasPayload = switch extractVariantSchema(commandSchema, ~index=variantIndex) {
    | Object(_) => true
    | _ => false
    }
    let commandName = extractCommandName(field)
    let resolver: GraphQL_ServerInstance.resolverFn = async (_root, args, ctx) => {
      switch handlerRef.contents {
      | Some(generateCommand) =>
        switch checkPluginStatus(~field) {
        | Some(rejected) => rejected
        | None =>
          let identity = extractIdentity(ctx)
          let rule = commandAuthorization(syntheticCommand(commandName, ~hasPayload))
          if !Reventless.Authorization.isAllowed(rule, identity) {
            rejectForbidden(~field)
          } else {
            let payload: CommandGenerator.payload = {
              command: commandName,
              arguments: args->Obj.magic,
              meta: {ip: [], user: identity.userId, info: `Mutation.${field}`},
              identity,
            }
            let outcome = await generateCommand(payload)->Effect.runPromise
            outcome->commandOutcomeToJson
          }
        }
      | None => JSON.Encode.null
      }
    }
    resolvers->Dict.set(field, resolver)
  })

  server.registerMutations(~sdlFields, ~resolvers)
}

// -- registerDcb (Phase 1 — synchronous, DCB StateChangeSlices) ---------------
// Called by Dcb_Builder via dcbMutationResolverHook. Registers SDL + resolver
// stubs for DCB mutations. Unlike aggregate mutations, DCB commands use tagged
// ID field(s) (e.g., itemId, or composite-partition members) — the envelope id
// is derived inside makeGenerateCommand from the command schema, so the resolver
// just forwards args verbatim.

let registerDcb = (
  ~fieldName: string,
  ~commandSchema: S.t<unknown>,
  ~commandAuthorization: unknown => Reventless.Authorization.permission,
  ~server: GraphQL_ServerInstance.t,
) => {
  ensureCommandResultTypes(server)
  let variantSchema = extractVariantSchema(commandSchema)
  let sdlFields = [deriveSdlField(~fieldName, variantSchema)]

  // Extract TAG (variant constructor name) for routing
  let constructorNames = Reventless.DcbTag.extractAllVariantNames(commandSchema->Obj.magic)
  let tag = constructorNames->Array.get(0)->Option.getOr(fieldName)
  let hasPayload = Reventless.DcbTag.isVariantPayloadBearing(commandSchema->Obj.magic, tag)

  let handlerRef = ref(None)
  handlerRefs->Dict.set(fieldName, handlerRef)

  let resolver: GraphQL_ServerInstance.resolverFn = async (_root, args, ctx) => {
    switch handlerRef.contents {
    | Some(generateCommand) =>
      switch checkPluginStatus(~field=fieldName) {
      | Some(rejected) => rejected
      | None =>
        let identity = extractIdentity(ctx)
        let rule = commandAuthorization(syntheticCommand(tag, ~hasPayload))
        if !Reventless.Authorization.isAllowed(rule, identity) {
          rejectForbidden(~field=fieldName)
        } else {
          let payload: CommandGenerator.payload = {
            command: tag,
            arguments: args->Obj.magic,
            meta: {ip: [], user: identity.userId, info: `Mutation.${fieldName}`},
            identity,
          }
          let outcome = await generateCommand(payload)->Effect.runPromise
          outcome->commandOutcomeToJson
        }
      }
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
