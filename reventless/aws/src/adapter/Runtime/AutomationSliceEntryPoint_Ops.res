// Typed cold-start core for the AutomationSlice / OutboundTranslationSlice
// Lambda entry point.
//
// The "typed core, thin shell" split (docs/plans/done/minimize-lambda-entrypoint-mjs-shell.md):
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
  /** Whether `dcbQueueUrl` is a FIFO queue. Absent in a config written before
      the flavor travelled with the URL, where `false` — a standard queue — is
      what these command topics actually are. */
  commandQueueIsFifo: option<bool>,
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
    commandQueueIsFifo: h->Dict.get("commandQueueIsFifo")->Option.flatMap(JSON.Decode.bool),
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

// The flavor comes from the handler config rather than being assumed. It used to
// be hardcoded FIFO while the command topics are standard queues, and SQS rejects
// the MessageGroupId a FIFO publisher attaches — a failure nothing had reached,
// because the role had no sqs:SendMessage to get that far.
let makePublishJsons = (queueUrl: string, ~isFifo: bool): ReventlessCore.CommandTopic.publishJsons => {
  let queue: Util_SQS_Runtime.resolvedQueue = {id: queueUrl, name: queueUrl, arn: ""}
  queue->CommandTopicChannel_SQS_Runtime.publishJsons(isFifo ? AWS.SQS_FIFO : AWS.SQS)
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
        save(id, row->Reventless.Util_Sury.toJson(rowSchema), ReventlessCore.QueryDb.Overwrite, None)
      )
      ->Promise.all
  }
}

// Rehydrate the in-memory TODO list from the slice's view table, once per
// container.
//
// `todoItems` is a module-level dict populated only by phase 1, so before this
// existed a cold start began with an empty list and every row already persisted
// was unreachable: `phase2` admits `Failed && retryCount < maxRetries`, but only
// for rows it can see. A transient failure whose container then recycled was
// stranded permanently, in a row reading `Failed` that nothing would ever pick
// up again — while `makeSyncTodoItems` kept faithfully writing it back out.
//
// Once per container rather than per invocation: within a container the dict is
// authoritative and `phase2` already re-attempts every actionable row on each
// batch, so re-reading would buy nothing and cost a scan each time. The backlog
// is therefore retried on the first event a new container handles.
//
// Memory wins on conflict. A row already in the dict may be mid-flight
// (`Processing`) or a status this invocation just advanced; the stored copy is
// by definition no fresher.
//
// Only `Pending` and `Failed` are read. `Completed` rows are the bulk of a
// mature table and are never actionable, and neither are `Abandoned` ones — a
// row whose retry budget is spent is terminal, so it is left in the table rather
// than carried into memory. That the status says so is what lets this filter
// decide it: `maxRetries` is Spec-level and still not known here, and before the
// status existed an exhausted row had to be loaded and then filtered out by
// `phase2`.
let makeLoadTodoItems = (
  ~queryDbTableName: string,
  ~todoItems: dict<'row>,
  ~rowSchema: S.t<'row>,
  ~comp: string,
): (unit => promise<unit>) => {
  let loaded = ref(false)
  async () =>
    if loaded.contents {
      ()
    } else {
      loaded := true
      let params: AwsSdk.DynamoDb.DocumentClient.ScanCommand.input = {
        tableName: queryDbTableName,
        consistentRead: true,
        filterExpression: "#s = :pending OR #s = :failed",
        expressionAttributeNames: [("#s", "status")]->Dict.fromArray,
        expressionAttributeValues: [
          (":pending", "Pending"->JSON.Encode.string),
          (":failed", "Failed"->JSON.Encode.string),
        ]->Dict.fromArray,
      }
      let restored = await Util_DynamoDb_Runtime.scanStream(params)
      ->Stream.runCollect
      ->Effect.map(items =>
        items->Array.reduce(0, (count, item) => {
          let json = item->JSON.stringifyAny->Option.getOr("")->JSON.parseOrThrow
          let id = json->JSON.Decode.object->Option.flatMap(d => d->Dict.get("id"))->Option.flatMap(JSON.Decode.string)
          switch id {
          | Some(id) if todoItems->Dict.get(id)->Option.isNone =>
            switch json->Reventless.Util_Sury.fromJson(rowSchema) {
            | row =>
              todoItems->Dict.set(id, row)
              count + 1
            | exception _ => count
            }
          | _ => count
          }
        })
      )
      ->Effect.catchAll(err =>
        ReventlessCore.EffectLogger.logError(
          ~comp,
          `restore: couldn't read pending TODO rows from ${queryDbTableName}: ${DynamoDb_Error.message(
              err,
            )}`,
        )->Effect.map(_ => 0)
      )
      ->Effect.runPromise
      if restored > 0 {
        ReventlessCore.EffectLogger.logInfo(
          ~comp,
          `restore: reloaded ${restored->Int.toString} unfinished TODO row(s) from ${queryDbTableName}`,
        )->Effect.runSync
      }
    }
}

// ── Platform capabilities ───────────────────────────────────────────────────

/**
What this Lambda hands a slice's `translate`.

Built here rather than reached for inside the plugin, because a plugin depends on
`reventless-spec` and cannot name Amazon Location — the whole point of the
injected record. This module is the AWS side of that seam and calls the SDK
directly: no proxy hop through the browser's Function URL, and no dependence on a
public unauthenticated endpoint for an unattended path.

Resolved per call rather than captured once, so a Lambda whose configuration is
updated does not need a cold start to see it. An unset `PLACE_INDEX_NAME` reaches
`Geocoder_AwsLocation_Backend` as `""`, which answers `Unavailable` — a retryable
outcome, not a verdict on the address.
*/
let capabilities = (): Reventless.Capabilities.t => {
  geocode: (~text) =>
    Geocoder_AwsLocation_Backend.search(
      ~indexName=NodeProcess.env->Dict.get("PLACE_INDEX_NAME")->Option.getOr(""),
      ~text,
    ),
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
// The entry point builds callbacks dynamically per HANDLER_CONFIG entry, so it
// cannot name `AutomationSlice_Callback.T` / `OutboundTranslationSlice_Callback.T`
// — the Spec is not known statically — and has to ascribe a structural type where
// the value crosses from the dynamically-imported JS module into ReScript.
//
// These are aliases of the protocol types each callback module owns, never
// restatements of them. That distinction is the whole point: a hand-written copy
// is a second source of truth the compiler cannot reconcile with the first, and
// it drifts silently. It did — when `phase1` gained its `sourceId` the copy here
// kept saying `array<'event>`, stayed internally consistent, compiled, and then
// destructured a bare event as a tuple at runtime, so every outbound slice on AWS
// died reading `.TAG` of `undefined` on its first record. As aliases, the same
// change is a compile error here instead.
type automationCallback = ReventlessCore.AutomationSlice_Callback.runtime
type outboundCallback<'event> = ReventlessCore.OutboundTranslationSlice_Callback.runtime<'event>

// Automation: phase 1 takes the RAW envelope JSONs — the callback routes by
// `meta.service` and unwraps `{id, meta, event}` itself — plus the context.
let makeAutomationJsonEventsHandler = (
  ~context: Reventless.AutomationSlice.context,
  ~callback: automationCallback,
  ~publishJsons: ReventlessCore.CommandTopic.publishJsons,
  ~syncTodoItems: unit => promise<unit>,
  ~loadTodoItems: unit => promise<unit>,
): ReventlessCore.EventCollector.jsonEventsHandler =>
  stream =>
    stream
    ->Stream.runCollect
    ->Effect.flatMap(jsons =>
      Effect.promise(async () => {
        await loadTodoItems()
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
  ~loadTodoItems: unit => promise<unit>,
): ReventlessCore.EventCollector.jsonEventsHandler => {
  let decoder = Reventless.DcbDecode.makeDecoder(consumedEventSchema)
  stream =>
    stream
    ->Stream.mapEffect(json =>
      Effect.sync(() => {
        let envelope = json->JSON.Decode.object
        let rawEvent = envelope->Option.flatMap(d => d->Dict.get("event"))->Option.getOr(json)
        // The entity the event was published for, mirroring the in-process
        // builder. An Aggregate's event payload does not repeat its own id, so
        // without lifting this out of the envelope `collect` cannot name the
        // subject of the outbound item it creates.
        let sourceId =
          envelope
          ->Option.flatMap(d => d->Dict.get("id"))
          ->Option.flatMap(JSON.Decode.string)
          ->Option.getOr("")
        let (eventType, dataDict) = rawEvent->ReventlessCore.Message.splitMessage
        switch decoder.decode(~eventType, ~data=dataDict) {
        | Some(event) => [(sourceId, event)]
        | None => []
        }
      })
    )
    ->Stream.flatMap(events => Stream.fromIterable(events))
    ->Stream.runCollect
    ->Effect.flatMap(events =>
      Effect.promise(async () => {
        await loadTodoItems()
        callback.phase1(events)
        await syncTodoItems()
        await callback.phase2(publishJsons, ~capabilities=capabilities())
        await syncTodoItems()
      })
    )
}

// ── Handler assembly (called by the shell per HANDLER_CONFIG entry) ─────────
// Comp matches what the slice's own callback logs under, so a filter catches
// both the framework's lines and the application handler's.

/**
A built slice, in the two ways the Lambda drives it.

`registered` handles a stream batch. `sweep` runs the TODO backlog with no event
to trigger it — the scheduled path, and the reason `translatePending` exists on
the in-process builder. Both close over the *same* publish/sync/load closures, so
a sweep landing on a container that has already served a batch reuses the load it
did then, and one landing cold does the reload itself.
*/
type builtSlice = {
  registered: StreamRoutedEntryPoint_Ops.registeredHandler,
  sweep: unit => promise<unit>,
  comp: string,
}

let makeAutomationRegisteredHandler = (
  entry: handlerEntry,
  ~sliceName: string,
  ~callback: automationCallback,
): builtSlice => {
  let comp = `AutomationSlice(${sliceName})`
  let publishJsons = makePublishJsons(
    entry.dcbQueueUrl,
    ~isFifo=entry.commandQueueIsFifo->Option.getOr(false),
  )
  let syncTodoItems = makeSyncTodoItems(
    ~queryDbTableName=entry.queryDbTableName,
    ~todoItems=callback.todoItems,
    ~rowSchema=ReventlessCore.AutomationSlice_Callback.todoRowSchema,
  )
  let loadTodoItems = makeLoadTodoItems(
    ~queryDbTableName=entry.queryDbTableName,
    ~todoItems=callback.todoItems,
    ~rowSchema=ReventlessCore.AutomationSlice_Callback.todoRowSchema,
    ~comp,
  )
  {
    registered: {
      handler: StreamRoutedEntryPoint_Ops.toStreamHandler(
        makeAutomationJsonEventsHandler(
          ~context=entry.context->Option.getOr(defaultContext(sliceName)),
          ~callback,
          ~publishJsons,
          ~syncTodoItems,
          ~loadTodoItems,
        ),
      ),
      comp,
    },
    sweep: async () => {
      await loadTodoItems()
      await callback.phase2(publishJsons)
      await syncTodoItems()
    },
    comp,
  }
}

let makeOutboundRegisteredHandler = (
  entry: handlerEntry,
  ~sliceName: string,
  ~consumedEventSchema: S.t<'event>,
  ~callback: outboundCallback<'event>,
): builtSlice => {
  let comp = `OutboundTranslationSlice(${sliceName})`
  let publishJsons = makePublishJsons(
    entry.dcbQueueUrl,
    ~isFifo=entry.commandQueueIsFifo->Option.getOr(false),
  )
  let syncTodoItems = makeSyncTodoItems(
    ~queryDbTableName=entry.queryDbTableName,
    ~todoItems=callback.todoItems,
    ~rowSchema=ReventlessCore.OutboundTranslationSlice_Callback.todoRowSchema,
  )
  let loadTodoItems = makeLoadTodoItems(
    ~queryDbTableName=entry.queryDbTableName,
    ~todoItems=callback.todoItems,
    ~rowSchema=ReventlessCore.OutboundTranslationSlice_Callback.todoRowSchema,
    ~comp,
  )
  {
    registered: {
      handler: StreamRoutedEntryPoint_Ops.toStreamHandler(
        makeOutboundJsonEventsHandler(
          ~consumedEventSchema,
          ~callback,
          ~publishJsons,
          ~syncTodoItems,
          ~loadTodoItems,
        ),
      ),
      comp,
    },
    sweep: async () => {
      await loadTodoItems()
      await callback.phase2(publishJsons, ~capabilities=capabilities())
      await syncTodoItems()
    },
    comp,
  }
}

/**
Run every slice's TODO backlog, for a scheduled invocation carrying no records.

Sequential rather than concurrent: the slices in one Lambda share its memory and
its downstream quotas, and a sweep is never latency-critical. A slice that throws
is logged and does not stop the rest — a sweep that abandoned the remaining
slices because one geocoder was down would be a worse version of the problem it
exists to fix.
*/
let runSweeps = async (slices: array<builtSlice>) => {
  for i in 0 to slices->Array.length - 1 {
    let slice = slices->Array.getUnsafe(i)
    try {
      await slice.sweep()
    } catch {
    | exn =>
      let msg = exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
      ReventlessCore.EffectLogger.logError(~comp=slice.comp, `sweep failed: ${msg}`)->Effect.runSync
    }
  }
}
