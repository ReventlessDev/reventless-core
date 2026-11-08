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

/**
Carries an encoded domain rejection from `Decision.decide` back to a synchronous producer.
`errorCode` is the variant tag of `Spec.errorSchema` (e.g. `"AlreadyExists"`); `errorDetail`
is the JSON-stringified error payload (or empty string for payload-less variants).
*/
type rejectedResult = {errorCode: string, errorDetail: string}

/** Why a command was refused; see `ReventlessInfra.CommandTopic.refusalCause`. */
type refusalCause = ReventlessInfra.CommandTopic.refusalCause =
  | DomainRejection
  | InfrastructureFailure
  | AccessRefusal

/** The `CommandRejectionCause` enum value a client sees for a cause. */
let refusalCauseToGraphQL = (cause: refusalCause): string =>
  switch cause {
  | DomainRejection => "DOMAIN"
  | AccessRefusal => "ACCESS"
  | InfrastructureFailure => "INFRASTRUCTURE"
  }

/**
What became of one command. Constructors are prefixed to stay clear of `commandOutcome`'s
`Accepted`/`Rejected` below — that type is the producer-facing result shape (and the GraphQL
`CommandResult` union); this one is the observation, and carries the refusal cause it doesn't.
*/
type observedOutcome =
  | OutcomeAccepted({entityId: option<string>, eventCount: int})
  | OutcomeRejected({errorCode: string, errorDetail: string, cause: refusalCause})

/** `reference` is the command's `meta.msgId` on every current transport.
    `correlationId` is the command's, where the reporting handler had its meta. */
type commandOutcomeReport = {
  component: string,
  reference: string,
  correlationId?: string,
  /** The message that caused the command: the event an automation or a translation acted on,
      when it sent the command. */
  causationId?: string,
  outcome: observedOutcome,
  /** A refusal of a command the platform sent itself, which nobody waited on: no
      person and no work item hears it. */
  unheard?: bool,
}

type commandOutcomeHook = commandOutcomeReport => unit

type registeredOutcomeHook = {id: int, hook: commandOutcomeHook}

/**
Module-level outcome listeners, in the shape the `RuntimeExtension` cold-start seam already
reaches — so an extension registers one from `onColdStart` alongside the interception and
publish hooks, and no new registration path is needed. Several may listen at once: an
extension and the platform that watches itself, say. None registered = no-op (default).
*/
let commandOutcomeHooks: ref<array<registeredOutcomeHook>> = ref([])
let nextOutcomeHookId = ref(0)

/** Adds a listener and returns the function that removes it. */
let registerCommandOutcome = (hook: commandOutcomeHook): (unit => unit) => {
  nextOutcomeHookId := nextOutcomeHookId.contents + 1
  let id = nextOutcomeHookId.contents
  commandOutcomeHooks := commandOutcomeHooks.contents->Array.concat([{id, hook}])
  () => commandOutcomeHooks := commandOutcomeHooks.contents->Array.filter(h => h.id != id)
}

/** Removes every listener. */
let clearCommandOutcome = () => {
  commandOutcomeHooks := []
}

/** Whether each outcome is also written as an info line, `command accepted` or `command
    rejected`, under `CommandTopic(<component>)` with the command's ids: where a deployed
    platform's tools read what became of a command. The local platform turns it off, since its
    tap carries every outcome already. */
let outcomeLines = ref(true)

let logOutcome = (r: commandOutcomeReport) => {
  let str = JSON.Encode.string
  let (message, fields) = switch r.outcome {
  | OutcomeAccepted({entityId, eventCount}) => (
      "command accepted",
      [("outcome", str("accepted")), ("eventCount", JSON.Encode.int(eventCount))]->Array.concat(
        entityId->Option.mapOr([], e => [("entityId", str(e))]),
      ),
    )
  | OutcomeRejected({errorCode, cause}) => (
      "command rejected",
      [
        ("outcome", str("rejected")),
        ("errorCode", str(errorCode)),
        ("cause", str(refusalCauseToGraphQL(cause))),
      ],
    )
  }
  let unheard = r.unheard->Option.getOr(false)
  let ids: EffectLogger.ids = {
    msgId: r.reference,
    correlationId: ?r.correlationId,
    causationId: ?r.causationId,
  }
  let detail = JSON.Object(
    Dict.fromArray(
      [("component", str(r.component))]
      ->Array.concat(fields)
      ->Array.concat(unheard ? [("unheard", JSON.Encode.bool(true))] : []),
    ),
  )
  let comp = `CommandTopic(${r.component})`

  (
    unheard
      ? EffectLogger.logWarn(~comp, ~ids, ~detail, `${message}, and nobody is told`)
      : EffectLogger.logInfo(~comp, ~ids, ~detail, message)
  )->Effect.runSync
}

// Fired from reportAccepted/reportRejected below, which both write-side kinds call
// unconditionally — so this sees fire-and-forget dispatches too, not just the ones a
// producer awaited on the side-channels.
//
// A throwing listener is logged and swallowed, and the others still hear: the outcome
// it observes has already happened, and letting an observer fail a completed command
// would make an extension an outage (the same failure policy the cold-start seam
// settled on).
let fireCommandOutcome = (
  ~component: string,
  ~reference: string,
  ~correlationId: option<string>=?,
  ~causationId: option<string>=?,
  ~unheard: option<bool>=?,
  outcome: observedOutcome,
) => {
  let report = {component, reference, ?correlationId, ?causationId, outcome, ?unheard}
  if outcomeLines.contents {
    try logOutcome(report) catch {
    | _ => ()
    }
  }
  switch commandOutcomeHooks.contents {
  | [] => ()
  | hooks =>
    hooks->Array.forEach(({hook}) =>
      switch hook(report) {
      | () => ()
      | exception err =>
        EffectLogger.logError(
          ~comp=`CommandTopic(${component})`,
          `command-outcome hook threw (ignored): ${err
            ->JsExn.fromException
            ->Option.flatMap(JsExn.message)
            ->Option.getOr("unknown")}`,
        )->Effect.runSync
      }
    )
  }
}

// Side-channel for publishJsonsAndWait result propagation.
// Set by runInlineAndCollect before invoking the handler; cleared after.
// Callback implementations call reportAccepted during inline dispatch.
let acceptedResultChannel: ref<option<(string, acceptedResult) => unit>> = ref(None)

// Sibling side-channel for rejections, with their cause. Read by runInlineAndCollect
// to build `Rejected` outcomes that carry the real error code, detail and cause.
let rejectedResultChannel: ref<option<(string, rejectedResult, refusalCause) => unit>> = ref(None)

/** Who is waiting inline for one command's outcome, keyed by its message id. Keyed
    rather than one slot so two inline runs in one process, overlapping or nested,
    each hear only their own commands. */
type inlineWaiter = {
  onAccepted: acceptedResult => unit,
  onRejected: (rejectedResult, refusalCause) => unit,
}
let inlineWaiters: dict<inlineWaiter> = Dict.make()

/**
Turn an `acting` verdict into the refusal a command handler reports, or `None` to let
`decide` run.

Shared by both handlers so they refuse in the same words. `errorCode` is `"Forbidden"`,
the code an `@authorize` refusal carries, so a client handles both alike. `isDefect` marks
a refusal that is the data's or the slice's fault rather than the caller's.
*/
type ownershipRefusal = {rejected: rejectedResult, isDefect: bool}

let ownershipRefusal = (
  verdict: Reventless.OwnerScope.acting,
  ~component: string,
  ~command: string,
): option<ownershipRefusal> => {
  let refuse = (~isDefect=false, why) => Some({
    rejected: {
      errorCode: Reventless.CommandOutcome.code(Forbidden),
      errorDetail: `${component}.${command}: ${why}`,
    },
    isDefect,
  })
  switch verdict {
  | MayAct => None
  | NotTheOwner(_) => refuse("the caller does not own what this command acts on")
  | CallerUnidentified => refuse("the caller could not be identified")
  | ConflictingOwners(owners) =>
    refuse(
      ~isDefect=true,
      `the history records ${owners->Array.length->Int.toString} different owners`,
    )
  | OwnerUnreadable =>
    refuse(~isDefect=true, "the partition this command acts on could not be named")
  }
}

// `~component` is the owning component's `Spec.name`: an outcome isn't interpretable without
// knowing which component produced it, and the side-channel (keyed per inline dispatch) never
// had to say. `~cause` is required rather than defaulted so a new rejection site has to state
// which kind it is instead of silently reporting infrastructure as a domain decision.
let reportAccepted = (
  ~component: string,
  ~correlationId: option<string>=?,
  ~causationId: option<string>=?,
  reference: string,
  result: acceptedResult,
) => {
  acceptedResultChannel.contents->Option.forEach(cb => cb(reference, result))
  inlineWaiters->Dict.get(reference)->Option.forEach(w => w.onAccepted(result))
  fireCommandOutcome(
    ~component,
    ~reference,
    ~correlationId?,
    ~causationId?,
    OutcomeAccepted({entityId: result.entityId, eventCount: result.eventCount}),
  )
}

/** `~claimed` is whether the command carries a caller claim, as every command the
    API generates does. A business or permission refusal of one without a claim that
    nobody waits on inline is a refusal nobody hears: it is logged as a warning and
    counted as `UnheardRefusal`. */
let reportRejected = (
  ~component: string,
  ~cause: refusalCause,
  ~correlationId: option<string>=?,
  ~causationId: option<string>=?,
  ~claimed: bool=true,
  reference: string,
  result: rejectedResult,
) => {
  rejectedResultChannel.contents->Option.forEach(cb => cb(reference, result, cause))
  let waiter = inlineWaiters->Dict.get(reference)
  waiter->Option.forEach(w => w.onRejected(result, cause))
  // An infrastructure failure is not final: the queue delivers the command again.
  let unheard = !claimed && waiter->Option.isNone && cause != InfrastructureFailure
  if unheard {
    Metrics.emitCount(~metric="UnheardRefusal", ~slice=component)
  }
  fireCommandOutcome(
    ~component,
    ~reference,
    ~correlationId?,
    ~causationId?,
    ~unheard,
    OutcomeRejected({errorCode: result.errorCode, errorDetail: result.errorDetail, cause}),
  )
}

// Placed here (rather than CommandTopic.res) so runInlineAndCollect can use commandOutcome
// without importing Adapter.res → @pulumi/pulumi. Re-exported by CommandTopic via include.
type commandOutcome = ReventlessInfra.CommandTopic.commandOutcome =
  | Accepted({msgId: string, entityId?: string, eventCount: int})
  | Rejected({msgId: string, errorCode: string, errorDetail: option<string>, cause: refusalCause})
  | Pending({msgId: string})

// Serialise a commandOutcome to the JSON shape the CommandResult GraphQL union
// expects — every variant carries an explicit `__typename` so AppSync (and any
// other spec-compliant GraphQL server) can resolve the abstract type at
// runtime. Shared between in-memory (graphql-yoga resolvers) and the AWS
// Lambda direct-invocation entry point so both surfaces stay byte-compatible.
let commandOutcomeToJson = (outcome: commandOutcome): JSON.t =>
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
  | Rejected({msgId, errorCode, errorDetail, cause}) =>
    JSON.Object(
      Dict.fromArray([
        ("__typename", JSON.String("CommandRejected")),
        ("msgId", JSON.String(msgId)),
        ("errorCode", JSON.String(errorCode)),
        ("errorDetail", errorDetail->Option.map(s => JSON.String(s))->Option.getOr(JSON.Null)),
        ("cause", JSON.String(refusalCauseToGraphQL(cause))),
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

type publishJsonsAndWait = ReventlessInfra.CommandTopic.publishJsonsAndWait

/** A refusal as one line for a work item's `lastError`: the code, then the detail. */
let describeRefusal = (~errorCode: string, ~errorDetail: option<string>) =>
  switch errorDetail {
  | Some(detail) if detail != "" => `${errorCode}: ${detail}`
  | _ => errorCode
  }

// Encode the full message body expected by CommandTopic_Callback: {id, meta, command}.
// Shared by LocalCommandTopicChannel and CommandTopicChannel_SQS_Sync.
let encodeCommandJson = (cmdJson: Reventless.Message.commandJson): JSON.t =>
  JSON.Encode.object(
    Dict.fromArray([
      ("id", JSON.Encode.string(cmdJson.id)),
      ("meta", cmdJson.meta->Reventless.Util_Sury.toJson(Reventless.Message.metaSchema)),
      ("command", cmdJson.commandJson),
    ]),
  )

// Runs handleCmds inline, waits on each command's outcome by its message id, and maps
// results to commandOutcome. Shared by LocalCommandTopicChannel and CommandTopicChannel_SQS_Sync.
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
  let rejectedResults: dict<(rejectedResult, refusalCause)> = Dict.make()
  let references = items->Array.map(item => item.reference)
  references->Array.forEach(reference =>
    inlineWaiters->Dict.set(
      reference,
      {
        onAccepted: result => acceptedResults->Dict.set(reference, result),
        onRejected: (result, cause) => rejectedResults->Dict.set(reference, (result, cause)),
      },
    )
  )
  let stopWaiting = () =>
    references->Array.forEach(reference => inlineWaiters->Dict.delete(reference))
  let results = try await handleCmds(Stream.fromIterable(items))->Effect.runPromise catch {
  | JsExn(e) =>
    stopWaiting()
    JsExn.throw(e)
  | exn =>
    stopWaiting()
    throw(exn)
  }
  stopWaiting()
  jsons->Array.mapWithIndex((cmdJson, i) => {
    let msgId = cmdJson.meta.msgId
    // A reported rejection takes precedence over both Accepted and the
    // synthesized "Conflict" — it carries the most informative error.
    switch rejectedResults->Dict.get(msgId) {
    | Some(({errorCode, errorDetail}, cause)) =>
      let detail = errorDetail == "" ? None : Some(errorDetail)
      Rejected({msgId, errorCode, errorDetail: detail, cause})
    | None =>
      switch results->Array.get(i) {
      // The handler failed outright: the platform, not the model.
      | Some(Error(msg)) =>
        Rejected({
          msgId,
          errorCode: Reventless.CommandOutcome.code(Conflict),
          errorDetail: Some(msg),
          cause: InfrastructureFailure,
        })
      | _ =>
        let ar = acceptedResults->Dict.get(msgId)->Option.getOr({eventCount: 0})
        switch ar.entityId {
        | Some(entityId) => Accepted({msgId, entityId, eventCount: ar.eventCount})
        | None => Accepted({msgId, eventCount: ar.eventCount})
        }
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

// Helper to extract type names from a schema (for variant types). Used to
// register every command constructor so the StateChangeSlice command-topic
// dispatcher can route incoming JSON payloads to the right handler — payload-
// less variants must be addressable too, so this calls extractAllVariantNames
// (the inclusive version) rather than extractVariantNames (DCB-event filter).
let extractTypeNamesFromSchema = (schema: S.t<unknown>): array<string> =>
  Reventless.DcbTag.extractAllVariantNames(schema)

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
