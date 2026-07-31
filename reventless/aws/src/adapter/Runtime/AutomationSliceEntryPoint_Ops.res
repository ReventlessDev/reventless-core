// Typed cold-start core for the AutomationSlice / OutboundTranslationSlice
// Lambda entry point.
//
// The "typed core, thin shell" split (docs/plans/minimize-lambda-entrypoint-mjs-shell.md):
// AutomationSliceEntryPoint.mjs keeps only the inherently-untyped seam — the
// dynamic `import()` of the spec + body modules named in HANDLER_CONFIG and
// the curried callback-functor applications consuming them
// (AutomationSlice_Callback.Make(Spec)(Automation) /
// OutboundTranslationSlice_Callback.Make(Spec)(Translation)). HANDLER_CONFIG
// parsing, the two phase-1/phase-2 pipelines, the TODO-list QueryDb sync, and
// handler registration live here, fully type-checked; the routed dispatch
// boundary is shared with the ReadModel / StateViewSlice entry points in
// StreamRoutedEntryPoint_Ops.
//
// This conversion also REPAIRS the wiring: the former `.mjs` predated the
// mixed-source callback rework — it applied the (now curried) functor to the
// spec module alone, read `todoItems.contents` (no longer a ref), and passed
// schema-decoded events to `phase1` (the automation callback now takes raw
// envelope JSONs plus a context). Any event through that Lambda threw at
// `callback.phase1`. The `bodyModule` and `context` HANDLER_CONFIG fields
// exist for this wiring (AutomationSliceRuntime_Builder_Single).


type handlerEntry = {
  specModule: string,
  bodyModule: string,
  callbackType: string,
  queryDbTableName: string,
  dcbQueueUrl: string,
  sourceUrn: string,
  context: option<Reventless.AutomationSlice.context>,
}

let strOf = (obj: dict<JSON.t>, key: string): option<string> =>
  obj->Dict.get(key)->Option.flatMap(JSON.Decode.string)

let decodeContext = (json: JSON.t): option<Reventless.AutomationSlice.context> =>
  json
  ->JSON.Decode.object
  ->Option.map(c => {
    Reventless.AutomationSlice.environment: c->strOf("environment")->Option.getOr("unknown"),
    platformName: c->strOf("platformName")->Option.getOr("unknown"),
    pluginName: c->strOf("pluginName")->Option.getOr("unknown"),
    sliceName: c->strOf("sliceName")->Option.getOr("unknown"),
  })

let decodeEntry = (json: JSON.t): option<handlerEntry> =>
  json
  ->JSON.Decode.object
  ->Option.map(h => {
    specModule: h->strOf("specModule")->Option.getOr(""),
    bodyModule: h->strOf("bodyModule")->Option.getOr(""),
    callbackType: h->strOf("callbackType")->Option.getOr("automation"),
    queryDbTableName: h->strOf("queryDbTableName")->Option.getOr(""),
    dcbQueueUrl: h->strOf("dcbQueueUrl")->Option.getOr(""),
    sourceUrn: h->strOf("sourceUrn")->Option.getOr(""),
    context: h->Dict.get("context")->Option.flatMap(decodeContext),
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

// A pre-`bodyModule` config entry cannot rebuild the callback (the spec module
// alone lacks the mappings/process). Warn and skip rather than crash the whole
// Lambda — co-hosted slices with complete entries still run.
let warnMissingBodyModule = (entry: handlerEntry) =>
  StreamRoutedEntryPoint_Ops.logWarn(
    `handler entry for spec '${entry.specModule}' carries no bodyModule (stale HANDLER_CONFIG?); skipping`,
    {comp: "AutomationSliceRuntime"},
  )

// Fallback for automation entries from a config without `context` — sliceName
// is the only field the runtime can still recover.
let defaultContext = (sliceName: string): Reventless.AutomationSlice.context => {
  environment: NodeProcess.env->Dict.get("Environment")->Option.getOr("unknown"),
  platformName: "unknown",
  pluginName: "unknown",
  sliceName,
}

// ── Shared plumbing ─────────────────────────────────────────────────────────

let makePublishJsons = (queueUrl: string): ReventlessCore.CommandTopic.publishJsons => {
  let queue: Util_SQS_Runtime.resolvedQueue = {id: queueUrl, name: queueUrl, arn: ""}
  queue->CommandTopicChannel_SQS_Runtime.publishJsons(AWS.SQS_FIFO)
}

// Overwrite-sync the in-memory TODO list into the slice's view table. Rows are
// serialized through the callback's row schema — the same JSON shape the
// deploy-time QueryDb writes.
let makeSyncTodoItems = (
  ~queryDbTableName: string,
  ~todoItems: dict<'row>,
  ~rowSchema: S.t<'row>,
): (unit => promise<unit>) => {
  let table: Util_DynamoDb_Runtime.resolvedTable = {
    id: "",
    name: queryDbTableName,
    arn: "",
    hashKey: "id",
  }
  let save = QueryDbStorage_DynamoDb_Runtime.save(table)
  async () => {
    let _ =
      await todoItems
      ->Dict.toArray
      ->Array.map(((id, row)) =>
        save(id, row->S.reverseConvertToJsonOrThrow(rowSchema), ReventlessCore.QueryDb.Overwrite, None)
      )
      ->Promise.all
  }
}

// ── Phase-1/phase-2 pipelines ───────────────────────────────────────────────
// Both run: collect the batch → phase 1 → sync (so consumers observe Pending
// rows even if phase 2 fails) → phase 2 → sync. Unlike the in-process builders
// (which DETACH phase 2 to avoid a local-bus self-deadlock), the Lambda AWAITS
// it: SQS decouples the downstream fan-out, and a detached promise would
// freeze with the runtime between invocations.

// The callback shapes the shell's functor applications produce
// (AutomationSlice_Callback.T / OutboundTranslationSlice_Callback.T), typed at
// the seam.
type automationCallback = {
  todoItems: dict<ReventlessCore.AutomationSlice_Callback.todoRow>,
  phase1: (array<JSON.t>, Reventless.AutomationSlice.context) => unit,
  phase2: ReventlessCore.CommandTopic.publishJsons => promise<unit>,
}
type outboundCallback<'event> = {
  todoItems: dict<ReventlessCore.OutboundTranslationSlice_Callback.todoRow>,
  phase1: array<'event> => unit,
  phase2: ReventlessCore.CommandTopic.publishJsons => promise<unit>,
}

// Automation: phase 1 takes the RAW envelope JSONs — the callback routes by
// `meta.service` and unwraps `{id, meta, event}` itself — plus the context.
let makeAutomationJsonEventsHandler = (
  ~context: Reventless.AutomationSlice.context,
  ~callback: automationCallback,
  ~publishJsons: ReventlessCore.CommandTopic.publishJsons,
  ~syncTodoItems: unit => promise<unit>,
): ReventlessCore.EventCollector.jsonEventsHandler =>
  stream =>
    stream
    ->Stream.runCollect
    ->Effect.flatMap(jsons =>
      Effect.promise(async () => {
        callback.phase1(jsons, context)
        await syncTodoItems()
        await callback.phase2(publishJsons)
        await syncTodoItems()
      })
    )

// Outbound: phase 1 takes DECODED consumed events. Mirrors the in-process
// builder's decode — the tolerant DcbDecode on the inner `event` payload, so
// event types the slice does not consume are dropped silently instead of
// logging an error per event.
let makeOutboundJsonEventsHandler = (
  ~consumedEventSchema: S.t<'event>,
  ~callback: outboundCallback<'event>,
  ~publishJsons: ReventlessCore.CommandTopic.publishJsons,
  ~syncTodoItems: unit => promise<unit>,
): ReventlessCore.EventCollector.jsonEventsHandler => {
  let decoder = Reventless.DcbDecode.makeDecoder(consumedEventSchema)
  stream =>
    stream
    ->Stream.mapEffect(json =>
      Effect.sync(() => {
        let rawEvent =
          json
          ->JSON.Decode.object
          ->Option.flatMap(d => d->Dict.get("event"))
          ->Option.getOr(json)
        let (eventType, dataDict) = rawEvent->ReventlessCore.Message.splitMessage
        switch decoder.decode(~eventType, ~data=dataDict) {
        | Some(event) => [event]
        | None => []
        }
      })
    )
    ->Stream.flatMap(events => Stream.fromIterable(events))
    ->Stream.runCollect
    ->Effect.flatMap(events =>
      Effect.promise(async () => {
        callback.phase1(events)
        await syncTodoItems()
        await callback.phase2(publishJsons)
        await syncTodoItems()
      })
    )
}

// ── Handler assembly (called by the shell per HANDLER_CONFIG entry) ─────────
// Comp matches what the slice's own callback logs under, so a filter catches
// both the framework's lines and the application handler's.

let makeAutomationRegisteredHandler = (
  entry: handlerEntry,
  ~sliceName: string,
  ~callback: automationCallback,
): StreamRoutedEntryPoint_Ops.registeredHandler => {
  handler: StreamRoutedEntryPoint_Ops.toStreamHandler(
    makeAutomationJsonEventsHandler(
      ~context=entry.context->Option.getOr(defaultContext(sliceName)),
      ~callback,
      ~publishJsons=makePublishJsons(entry.dcbQueueUrl),
      ~syncTodoItems=makeSyncTodoItems(
        ~queryDbTableName=entry.queryDbTableName,
        ~todoItems=callback.todoItems,
        ~rowSchema=ReventlessCore.AutomationSlice_Callback.todoRowSchema,
      ),
    ),
  ),
  comp: `AutomationSlice(${sliceName})`,
}

let makeOutboundRegisteredHandler = (
  entry: handlerEntry,
  ~sliceName: string,
  ~consumedEventSchema: S.t<'event>,
  ~callback: outboundCallback<'event>,
): StreamRoutedEntryPoint_Ops.registeredHandler => {
  handler: StreamRoutedEntryPoint_Ops.toStreamHandler(
    makeOutboundJsonEventsHandler(
      ~consumedEventSchema,
      ~callback,
      ~publishJsons=makePublishJsons(entry.dcbQueueUrl),
      ~syncTodoItems=makeSyncTodoItems(
        ~queryDbTableName=entry.queryDbTableName,
        ~todoItems=callback.todoItems,
        ~rowSchema=ReventlessCore.OutboundTranslationSlice_Callback.todoRowSchema,
      ),
    ),
  ),
  comp: `OutboundTranslationSlice(${sliceName})`,
}
