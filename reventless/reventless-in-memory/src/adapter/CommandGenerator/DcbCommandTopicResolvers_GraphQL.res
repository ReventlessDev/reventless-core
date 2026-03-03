// GraphQL mutation resolvers for in-memory DCB StateChangeSlices.
// Registers one GraphQL mutation field per StateChangeSlice.
// Each resolver builds the command JSON body and dispatches to the registered
// StateChangeSlice handler via CommandTopic.getHandlers (global registry).
//
// This mirrors CommandGeneratorResolvers_GraphQL for aggregate mutations,
// but routes through the DCB handler chain instead of generateCommand.

@@warning("-44")
open ReventlessCore

let register = (~fieldName: string) => {
  let sdlFields = [`  ${fieldName}(id: ID, args: String): String`]

  let resolver: GraphQL_Server.resolverFn = async (_root, args) => {
    let argsDict: dict<JSON.t> = args->Obj.magic
    let id = switch argsDict->Dict.get("id") {
    | Some(JSON.String(s)) => s
    | _ => ""
    }
    let argsStr = switch argsDict->Dict.get("args") {
    | Some(JSON.String(s)) => s
    | _ => "{}"
    }

    let commandPayload = try {
      JSON.parseOrThrow(argsStr)
    } catch {
    | _ => JSON.Encode.object(Dict.make())
    }

    // Extract TAG from the command payload to route to the correct handler.
    // DCB commands are tagged variants — sury serializes them with a "TAG" field.
    let typeName = switch commandPayload {
    | JSON.Object(d) =>
      switch d->Dict.get("TAG") {
      | Some(JSON.String(s)) => s
      | _ => ""
      }
    | _ => ""
    }

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
    let handlers = CommandTopic.getHandlers(typeName)
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
