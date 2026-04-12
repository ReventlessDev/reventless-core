// Re-export from spec so ReventlessCore.CommandTopic.topicItem === ReventlessInfra.CommandTopic.topicItem
type topicItem<'command> = ReventlessInfra.CommandTopic.topicItem<'command>

type jsonCommandsHandler = ReventlessInfra.CommandTopic.commandsHandler<JSON.t>

/**
Carries entity identity and event count from a successful synchronous command dispatch.
Populated by `StateChangeSlice_Callback.handleSingleCommand` and `Aggregate_Callback.replayProcessAppend`
during inline `publishJsonsAndWait` execution and read by `runInlineAndCollect` to build
`CommandTopic.Accepted` outcomes.
*/
type acceptedResult = {entityId?: string, eventCount: int}

// Side-channel for publishJsonsAndWait result propagation.
// Set by runInlineAndCollect before invoking the handler; cleared after.
// Callback implementations call reportAccepted during inline dispatch.
let acceptedResultChannel: ref<option<(string, acceptedResult) => unit>> = ref(None)

let reportAccepted = (reference: string, result: acceptedResult) =>
  acceptedResultChannel.contents->Option.forEach(cb => cb(reference, result))

// Placed here (rather than CommandTopic.res) so runInlineAndCollect can use commandOutcome
// without importing Adapter.res → @pulumi/pulumi. Re-exported by CommandTopic via include.
type commandOutcome =
  | Accepted({msgId: string, entityId?: string, eventCount: int})
  | Rejected({msgId: string, errorCode: string, errorDetail: option<string>})
  | Pending({msgId: string})

type publishJsonsAndWait = array<Reventless.Message.commandJson> => promise<array<commandOutcome>>

// Encode the full message body expected by CommandTopic_Callback: {id, meta, command}.
// Shared by CommandTopicChannel_InMemory and CommandTopicChannel_SQS_Sync.
let encodeCommandJson = (cmdJson: Reventless.Message.commandJson): JSON.t =>
  JSON.Encode.object(
    Dict.fromArray([
      ("id", JSON.Encode.string(cmdJson.id)),
      ("meta", cmdJson.meta->S.reverseConvertToJsonOrThrow(Reventless.Message.metaSchema)),
      ("command", cmdJson.commandJson),
    ]),
  )

// Runs handleCmds inline, manages the acceptedResultChannel side-channel, and maps
// results to commandOutcome. Shared by CommandTopicChannel_InMemory and CommandTopicChannel_SQS_Sync.
let runInlineAndCollect = async (
  jsons: array<Reventless.Message.commandJson>,
  handleCmds: jsonCommandsHandler,
) => {
  let items = jsons->Array.map((cmdJson: Reventless.Message.commandJson) => {
    let reference = cmdJson.meta.msgId
    let item: topicItem<JSON.t> = {command: encodeCommandJson(cmdJson), reference}
    item
  })
  let acceptedResults: dict<acceptedResult> = Dict.make()
  acceptedResultChannel.contents = Some(
    (reference, result) => acceptedResults->Dict.set(reference, result),
  )
  let results = await handleCmds(Stream.fromIterable(items))->Effect.runPromise
  acceptedResultChannel.contents = None
  jsons->Array.mapWithIndex((cmdJson, i) => {
    let msgId = cmdJson.meta.msgId
    switch results->Array.get(i) {
    | Some(Error(msg)) =>
      Rejected({msgId, errorCode: "Conflict", errorDetail: Some(msg)})
    | _ =>
      let ar = acceptedResults->Dict.get(msgId)->Option.getOr({eventCount: 0})
      switch ar.entityId {
      | Some(entityId) => Accepted({msgId, entityId, eventCount: ar.eventCount})
      | None => Accepted({msgId, eventCount: ar.eventCount})
      }
    }
  })
}

// Convenience helper for test code that needs to call a stream handler with an array
// (for use in packages that don't have rescript-effect as a direct dependency)
let callHandlerWithArray: (
  jsonCommandsHandler,
  array<topicItem<JSON.t>>,
) => promise<array<result<string, string>>> = (handler, items) =>
  handler(Stream.fromIterable(items))->Effect.runPromise

// Helper to extract type names from a schema (for variant types)
// For a variant type like `type command = CreateItem({...}) | UpdateItem({...})`,
// this extracts ["CreateItem", "UpdateItem"]
let extractTypeNamesFromSchema = (schema: S.t<unknown>): array<string> =>
  Reventless.DcbTag.extractEventTypes(schema)

// Global registry for schema-based filtering
// Keyed by command type name (e.g., "CreateItem", "UpdateItem")
type handlerEntry = {
  schema: S.t<unknown>,
  handler: jsonCommandsHandler,
}
type registry = Dict.t<array<handlerEntry>>
let globalRegistry: registry = Dict.make()

// Register a handler with the global registry
// This is called by StateChangeSlice to register its command handler
let registerHandler = (
  ~schema: S.t<unknown>,
  ~handler: jsonCommandsHandler,
  ~typeNames: array<string>,
) => {
  typeNames->Array.forEach(typeName => {
    let existing = globalRegistry->Dict.get(typeName)->Option.getOr([])
    globalRegistry->Dict.set(typeName, existing->Array.concat([{schema, handler}]))
  })
}

// Get handlers for a specific command type name
let getHandlers = (typeName: string): array<handlerEntry> =>
  globalRegistry->Dict.get(typeName)->Option.getOr([])
