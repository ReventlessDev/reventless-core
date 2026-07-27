// Typed cold-start core for the SideEffectHandler Lambda entry point.
//
// The "typed core, thin shell" split (docs/plans/minimize-lambda-entrypoint-mjs-shell.md):
// SideEffectEntryPoint.mjs keeps only the untyped seam — the dynamic `import()`
// of the side-effect modules named in HANDLER_CONFIG and the
// SideEffectHandler_Callback.Make functor application consuming them.
// HANDLER_CONFIG parsing and handler registration live here, fully
// type-checked; the routed dispatch boundary is shared with the other
// stream-routed entry points in StreamRoutedEntryPoint_Ops.

type handlerEntry = {
  sourceUrn: string,
  sideEffectModules: array<string>,
  // Resolved at deploy time and baked into HANDLER_CONFIG
  // (SideEffectHandlerRuntime_Builder_Single) — the shell has only module paths
  // to identify a handler by.
  comp: option<string>,
  plugin: option<string>,
}

let strOf = (obj: dict<JSON.t>, key: string): option<string> =>
  obj->Dict.get(key)->Option.flatMap(JSON.Decode.string)

let decodeEntry = (json: JSON.t): option<handlerEntry> =>
  json
  ->JSON.Decode.object
  ->Option.map(h => {
    sourceUrn: h->strOf("sourceUrn")->Option.getOr(""),
    sideEffectModules: h
    ->Dict.get("sideEffectModules")
    ->Option.flatMap(JSON.Decode.array)
    ->Option.getOr([])
    ->Array.filterMap(JSON.Decode.string),
    comp: h->strOf("comp"),
    plugin: h->strOf("plugin"),
  })

let parseHandlerConfig = (rawJson: string): array<handlerEntry> =>
  rawJson == ""
    ? []
    : rawJson
      ->JSON.parseOrThrow
      ->JSON.Decode.object
      ->Option.flatMap(obj => obj->Dict.get("handlers"))
      ->Option.flatMap(JSON.Decode.array)
      ->Option.getOr([])
      ->Array.filterMap(decodeEntry)

// Side effects are fire-and-forget consumers with no query access in the
// bundled handler — same restriction as the former shell's no-op stub.
let noopQueryEngine: Reventless.QueryEngine.operations = {
  scan: async (~readModelName as _, ~filterConfigs as _, ~limit as _) => [],
  query: async (
    ~readModelName as _,
    ~key as _=?,
    ~id as _,
    ~subIdConfig as _=?,
    ~filterConfigs as _=?,
    ~ascending as _=?,
    ~limit as _=?,
  ) => [],
}

let makeRegisteredHandler = (
  entry: handlerEntry,
  handleJsonEvents: ReventlessCore.EventCollector.jsonEventsHandler,
): StreamRoutedEntryPoint_Ops.registeredHandler => {
  handler: StreamRoutedEntryPoint_Ops.toStreamHandler(handleJsonEvents),
  comp: ?entry.comp,
  plugin: ?entry.plugin,
}
