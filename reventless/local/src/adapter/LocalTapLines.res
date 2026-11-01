// The lines the event tap carries besides events: what became of each command,
// and each row a projection changed. Both go to the tap's listeners only; a
// rejected command is also kept in the log feed's problem ring.
//
// They are sent without the tap's sentinel prefix, as the `skipped` line is, and
// each carries a `kind`, so a reader that picks event lines by the prefix passes
// over them.

module Logger = ReventlessCore.Logger
module Outcome = ReventlessCore.CommandTopic_Helpers
module ViewChange = ReventlessCore.ViewChange

let str = JSON.Encode.string
let now = () => Date.make()->Date.toISOString

let lineOf = (fields: array<(string, JSON.t)>): string =>
  fields->Dict.fromArray->JSON.Encode.object->JSON.stringify

let optional = (name: string, value: option<string>): array<(string, JSON.t)> =>
  value->Option.mapOr([], v => [(name, str(v))])

// ─── Command outcomes ────────────────────────────────────────────────────────

/** The component a report names, as the log lines of its handler name it. */
let compOf = (r: Outcome.commandOutcomeReport) => `CommandTopic(${r.component})`

let pluginOf = (r: Outcome.commandOutcomeReport) => Logger.resolvePlugin(~comp=compOf(r), ())

/** The tap line for one outcome. */
let outcomeLine = (r: Outcome.commandOutcomeReport): string => {
  let plugin = pluginOf(r)
  let head =
    [("kind", str("commandOutcome")), ("component", str(r.component))]
    ->Array.concat(optional("plugin", plugin))
    ->Array.concat([("msgId", str(r.reference))])
    ->Array.concat(optional("correlationId", r.correlationId))
  let body = switch r.outcome {
  | OutcomeAccepted({entityId, eventCount}) =>
    [("outcome", str("accepted"))]
    ->Array.concat(optional("entityId", entityId))
    ->Array.concat([("eventCount", JSON.Encode.int(eventCount))])
  | OutcomeRejected({errorCode, cause}) => [
      ("outcome", str("rejected")),
      ("errorCode", str(errorCode)),
      ("cause", str(Outcome.refusalCauseToGraphQL(cause))),
    ]
  }
  lineOf(head->Array.concat(body)->Array.concat([("ts", str(now()))]))
}

/** A rejection as a log record: an error when the platform failed, a warning
    when the model or the caller's access refused. The detail is redacted as a
    logged detail is. */
let rejectionRecord = (r: Outcome.commandOutcomeReport): option<Logger.record> =>
  switch r.outcome {
  | OutcomeAccepted(_) => None
  | OutcomeRejected({errorCode, errorDetail, cause}) =>
    let level: Logger.level = switch cause {
    | InfrastructureFailure => Error
    | DomainRejection | AccessRefusal => Warn
    }
    let detailJson = switch errorDetail {
    | "" => []
    | text =>
      let parsed = try JSON.parseOrThrow(text) catch {
      | _ => str(text)
      }
      [("errorDetail", parsed->Reventless.LogRedaction.redactJson->Logger.truncateDetail)]
    }
    let annotations = Dict.fromArray([("msgId", r.reference)])
    r.correlationId->Option.forEach(id => annotations->Dict.set("correlationId", id))
    Some({
      time: now(),
      level,
      message: "command rejected",
      service: ?Logger.serviceName(),
      plugin: ?pluginOf(r),
      comp: compOf(r),
      annotations,
      detail: [
        ("component", str(r.component)),
        ("errorCode", str(errorCode)),
        ("cause", str(Outcome.refusalCauseToGraphQL(cause))),
      ]
      ->Array.concat(detailJson)
      ->Dict.fromArray
      ->JSON.Encode.object,
    })
  }

let onOutcome = (r: Outcome.commandOutcomeReport) => {
  rejectionRecord(r)->Option.forEach(LocalLogFeed.keepProblem)
  if LocalEventTap.hasReaders() {
    LocalEventTap.publish({
      line: outcomeLine(r),
      facets: {plugin: ?pluginOf(r), correlationId: ?r.correlationId},
    })
  }
}

// ─── View changes ────────────────────────────────────────────────────────────

/** The tap line for one row change: the summary the log line carries, with the
    row before and after, redacted. */
let viewChangeLine = (c: ViewChange.t): string => {
  let side = (name, value: option<JSON.t>) =>
    value->Option.mapOr([], v => [
      (name, v->Reventless.LogRedaction.redactJson->Logger.truncateDetail),
    ])
  lineOf(
    [("kind", str("viewChange"))]
    ->Array.concat(c->ViewChange.summaryFields)
    ->Array.concat(optional("correlationId", c.correlationId))
    ->Array.concat(side("before", c.before))
    ->Array.concat(side("after", c.after))
    ->Array.concat([("ts", str(now()))]),
  )
}

let onViewChange = (c: ViewChange.t) =>
  if LocalEventTap.hasReaders() {
    LocalEventTap.publish({
      line: viewChangeLine(c),
      facets: {
        // The plugin is looked up by the view's name, as a log line's is by the
        // name inside its component.
        plugin: ?Logger.resolvePlugin(~comp=`View(${c.view})`, ()),
        correlationId: ?c.correlationId,
      },
    })
  }

// ─── Registration ────────────────────────────────────────────────────────────

let removals: ref<array<unit => unit>> = ref([])

/** Starts sending both lines, once per process. */
let install = () =>
  if removals.contents == [] {
    removals := [Outcome.registerCommandOutcome(onOutcome), ViewChange.register(onViewChange)]
  }

/** Test seam: stops sending them. */
let resetForTests = () => {
  removals.contents->Array.forEach(remove => remove())
  removals := []
}
