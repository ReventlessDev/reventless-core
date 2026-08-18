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
Carries an encoded domain rejection from `Behavior.decide` back to a synchronous producer.
`errorCode` is the variant tag of `Spec.errorSchema` (e.g. `"AlreadyExists"`); `errorDetail`
is the JSON-stringified error payload (or empty string for payload-less variants).
*/
type rejectedResult = {errorCode: string, errorDetail: string}

/**
Why a command was refused.

`DomainRejection` is `Behavior.decide` returning `Error` — the model declining the command,
which is the model working. `InfrastructureFailure` is the decision never landing: an event-log
append that failed outright or exhausted its conflict retries. Both arrive on `reportRejected`,
so without this a consumer would read a broken event log as a business rejection.
*/
type refusalCause = DomainRejection | InfrastructureFailure

/**
What became of one command. Constructors are prefixed to stay clear of `commandOutcome`'s
`Accepted`/`Rejected` below — that type is the producer-facing result shape (and the GraphQL
`CommandResult` union); this one is the observation, and carries the refusal cause it doesn't.
*/
type observedOutcome =
  | OutcomeAccepted({entityId: option<string>, eventCount: int})
  | OutcomeRejected({errorCode: string, errorDetail: string, cause: refusalCause})

/** `reference` is the command's `meta.msgId` on every current transport. */
type commandOutcomeReport = {
  component: string,
  reference: string,
  outcome: observedOutcome,
}

type commandOutcomeHook = commandOutcomeReport => unit

/**
Module-level outcome hook, in the shape the `RuntimeExtension` cold-start seam already reaches
— so an extension registers it from `onColdStart` alongside the interception and publish hooks,
and no new registration path is needed. None = no-op (default).
*/
let commandOutcomeHook: ref<option<commandOutcomeHook>> = ref(None)

let registerCommandOutcome = (hook: commandOutcomeHook) => {
  commandOutcomeHook.contents = Some(hook)
}

let clearCommandOutcome = () => {
  commandOutcomeHook.contents = None
}

// Fired from reportAccepted/reportRejected below, which both write-side kinds call
// unconditionally — so this sees fire-and-forget dispatches too, not just the ones a
// producer awaited on the side-channels.
//
// A throwing hook is logged and swallowed: the outcome it observes has already happened,
// and letting an observer fail a completed command would make an extension an outage
// (the same failure policy the cold-start seam settled on).
let fireCommandOutcome = (~component: string, ~reference: string, outcome: observedOutcome) =>
  commandOutcomeHook.contents->Option.forEach(hook =>
    switch hook({component, reference, outcome}) {
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

// Side-channel for publishJsonsAndWait result propagation.
// Set by runInlineAndCollect before invoking the handler; cleared after.
// Callback implementations call reportAccepted during inline dispatch.
let acceptedResultChannel: ref<option<(string, acceptedResult) => unit>> = ref(None)

// Sibling side-channel for domain rejections — populated by callbacks when
// `Behavior.decide` returns `Error`. Read by runInlineAndCollect to build
// `Rejected` outcomes that carry the real error code and detail.
let rejectedResultChannel: ref<option<(string, rejectedResult) => unit>> = ref(None)

// `~component` is the owning component's `Spec.name`: an outcome isn't interpretable without
// knowing which component produced it, and the side-channel (keyed per inline dispatch) never
// had to say. `~cause` is required rather than defaulted so a new rejection site has to state
// which kind it is instead of silently reporting infrastructure as a domain decision.
let reportAccepted = (~component: string, reference: string, result: acceptedResult) => {
  acceptedResultChannel.contents->Option.forEach(cb => cb(reference, result))
  fireCommandOutcome(
    ~component,
    ~reference,
    OutcomeAccepted({entityId: result.entityId, eventCount: result.eventCount}),
  )
}

let reportRejected = (
  ~component: string,
  ~cause: refusalCause,
  reference: string,
  result: rejectedResult,
) => {
  rejectedResultChannel.contents->Option.forEach(cb => cb(reference, result))
  fireCommandOutcome(
    ~component,
    ~reference,
    OutcomeRejected({errorCode: result.errorCode, errorDetail: result.errorDetail, cause}),
  )
}

// Placed here (rather than CommandTopic.res) so runInlineAndCollect can use commandOutcome
// without importing Adapter.res → @pulumi/pulumi. Re-exported by CommandTopic via include.
type commandOutcome =
  | Accepted({msgId: string, entityId?: string, eventCount: int})
  | Rejected({msgId: string, errorCode: string, errorDetail: option<string>})
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

type publishJsonsAndWait = array<Reventless.Message.commandJson> => promise<array<commandOutcome>>

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

// Runs handleCmds inline, manages the acceptedResultChannel side-channel, and maps
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
  let rejectedResults: dict<rejectedResult> = Dict.make()
  acceptedResultChannel.contents = Some(
    (reference, result) => acceptedResults->Dict.set(reference, result),
  )
  rejectedResultChannel.contents = Some(
    (reference, result) => rejectedResults->Dict.set(reference, result),
  )
  let results = await handleCmds(Stream.fromIterable(items))->Effect.runPromise
  acceptedResultChannel.contents = None
  rejectedResultChannel.contents = None
  jsons->Array.mapWithIndex((cmdJson, i) => {
    let msgId = cmdJson.meta.msgId
    // Domain rejection from Behavior.decide takes precedence over both Accepted
    // and the synthesized "Conflict" — it carries the most informative error.
    switch rejectedResults->Dict.get(msgId) {
    | Some({errorCode, errorDetail}) =>
      let detail = errorDetail == "" ? None : Some(errorDetail)
      Rejected({msgId, errorCode, errorDetail: detail})
    | None =>
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
