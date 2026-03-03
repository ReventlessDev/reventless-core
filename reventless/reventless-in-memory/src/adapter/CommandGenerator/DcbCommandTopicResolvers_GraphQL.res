// GraphQL mutation resolvers for in-memory DCB StateChangeSlices.
// Registers one GraphQL mutation field per StateChangeSlice.
// Each resolver builds the command JSON body and dispatches to the registered
// StateChangeSlice handler via CommandTopic.getHandlers (global registry).
//
// This mirrors CommandGeneratorResolvers_GraphQL for aggregate mutations,
// but routes through the DCB handler chain instead of generateCommand.

@@warning("-44")
open ReventlessCore

let register = (~fieldName: string, ~commandSchema: S.t<unknown>) => {
  // Derive SDL from command schema — same derivation as fragment generator.
  // DCB commands are single-variant unions; extract the Object variant.
  let variantSchema = switch commandSchema {
  | Union({anyOf}) => anyOf->Array.get(0)->Option.getOr(commandSchema)
  | _ => commandSchema
  }

  let sdlFields = switch GraphQL_FragmentGenerator.deriveMutationFieldFromObject(
    ~fieldName,
    variantSchema,
    ~authorization=None,
  ) {
  | Some(field) => [field]
  | None => [`  ${fieldName}: String!`]
  }

  // Extract TAG (variant constructor name) for routing to correct handler
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

  let resolver: GraphQL_Server.resolverFn = async (_root, args) => {
    let argsDict: dict<JSON.t> = args->Obj.magic

    // Extract entity ID from the tagged field
    let id = switch idFieldName {
    | Some(idField) =>
      switch argsDict->Dict.get(idField) {
      | Some(JSON.String(s)) => s
      | _ => ""
      }
    | None => ""
    }

    // Build command payload from individual args + TAG
    let commandDict = Dict.make()
    commandDict->Dict.set("TAG", JSON.Encode.string(tag))
    argsDict->Dict.toArray->Array.forEach(((k, v)) =>
      if k !== "TAG" { commandDict->Dict.set(k, v) }
    )
    let commandPayload = JSON.Encode.object(commandDict)

    // Build the full message body that StateChangeSlice_Builder.makeJsonHandler
    // expects to decode via Message.decodeCommand'.
    let metaJson = JSON.Encode.object(
      Dict.fromArray([
        ("service", JSON.Encode.string("graphql")),
        ("time", JSON.Encode.string("")),
        ("ip", JSON.Encode.string("127.0.0.1")),
        ("user", JSON.Encode.string("local")),
        ("msgId", JSON.Encode.string("")),
        ("correlationId", JSON.Encode.string("")),
      ]),
    )
    let fullBody = JSON.Encode.object(
      Dict.fromArray([
        ("id", JSON.Encode.string(id)),
        ("meta", metaJson),
        ("command", commandPayload),
      ]),
    )

    // Route directly to registered handlers (same approach as test publishJsons routing).
    let handlers = CommandTopic.getHandlers(tag)
    let item: ReventlessInfra.CommandTopic.topicItem<JSON.t> = {
      command: fullBody,
      reference: id,
    }
    let allResults: array<result<string, string>> = []
    let _ =
      await handlers
      ->Array.map(async handlerEntry => {
        let {CommandTopic.handler: handler} = handlerEntry
        try {
          let results =
            await handler(Stream.fromIterable([item]))->Effect.runPromise
          allResults->Array.pushMany(results)
        } catch {
        | _ => ()
        }
      })
      ->Promise.all

    let hasError =
      allResults->Array.some(r =>
        switch r {
        | Error(_) => true
        | Ok(_) => false
        }
      )
    if hasError {
      let errorMsgs =
        allResults->Array.filterMap(r =>
          switch r {
          | Error(e) => Some(e)
          | Ok(_) => None
          }
        )
      errorMsgs->Array.join(", ")->JSON.Encode.string
    } else {
      "ok"->JSON.Encode.string
    }
  }

  let resolvers = Dict.make()
  resolvers->Dict.set(fieldName, resolver)
  GraphQL_Server.registerMutations(~sdlFields, ~resolvers)
}
