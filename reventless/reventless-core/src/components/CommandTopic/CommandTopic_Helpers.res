// Re-export from spec so ReventlessCore.CommandTopic.topicItem === Reventless.CommandTopic.topicItem
type topicItem<'command> = Reventless.CommandTopic.topicItem<'command>

type jsonCommandsHandler =
  Stream.t<topicItem<JSON.t>, string, unit> => Effect.t<array<result<string, string>>, string, unit>

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
