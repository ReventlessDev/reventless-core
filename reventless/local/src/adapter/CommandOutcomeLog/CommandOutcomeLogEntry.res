// One stored command outcome: the line the tap sends for it (component, plugin, message id,
// flow, cause, accepted with its entity and event count or rejected with its code), with the
// columns a read filters by.

type t = {
  seq: int,
  flow?: string,
  msgId: string,
  /** The tap's `commandOutcome` line, as JSON. */
  item: JSON.t,
}

/** What a read asks for: every field narrows, none reads every outcome. `startsFlow` keeps the
    commands that started a flow: an API request, an inbound translation, a timer's work item. */
type filter = {correlationId?: string, msgId?: string, startsFlow?: bool}

/** A flow's first command is the one whose flow id is its own message id. */
let startsFlow = (e: t) => e.flow == Some(e.msgId)

let matches = (f: filter, e: t) =>
  f.correlationId->Option.mapOr(true, c => e.flow == Some(c)) &&
  f.msgId->Option.mapOr(true, m => e.msgId == m) &&
  (f.startsFlow != Some(true) || startsFlow(e))

let filterOfJson = (j: option<JSON.t>): filter => {
  let d = j->Option.flatMap(JSON.Decode.object)->Option.getOr(Dict.make())
  let s = k => d->Dict.get(k)->Option.flatMap(JSON.Decode.string)
  {
    correlationId: ?s("correlationId"),
    msgId: ?s("msgId"),
    startsFlow: ?(d->Dict.get("startsFlow")->Option.flatMap(JSON.Decode.bool)),
  }
}
