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

/** What a read asks for: every field narrows, none reads every outcome. */
type filter = {correlationId?: string, msgId?: string}

let matches = (f: filter, e: t) =>
  f.correlationId->Option.mapOr(true, c => e.flow == Some(c)) &&
    f.msgId->Option.mapOr(true, m => e.msgId == m)

let filterOfJson = (j: option<JSON.t>): filter => {
  let d = j->Option.flatMap(JSON.Decode.object)->Option.getOr(Dict.make())
  let s = k => d->Dict.get(k)->Option.flatMap(JSON.Decode.string)
  {correlationId: ?s("correlationId"), msgId: ?s("msgId")}
}
