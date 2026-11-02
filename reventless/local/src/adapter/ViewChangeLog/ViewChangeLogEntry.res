// One stored row change: the line the tap sends for it (view, key, kind, fields, sources,
// flow, the row before and after, redacted), with the columns a read filters by.

type t = {
  seq: int,
  flow?: string,
  view: string,
  key: string,
  /** The message ids of the events behind it. */
  msgIds: array<string>,
  /** The tap's `viewChange` line, as JSON. */
  item: JSON.t,
}

/** What a read asks for: every field narrows, none reads every change. */
type filter = {
  correlationId?: string,
  msgId?: string,
  view?: string,
  key?: string,
}

let matches = (f: filter, e: t) =>
  f.correlationId->Option.mapOr(true, c => e.flow == Some(c)) &&
  f.msgId->Option.mapOr(true, m => e.msgIds->Array.includes(m)) &&
  f.view->Option.mapOr(true, v => e.view == v) &&
  f.key->Option.mapOr(true, k => e.key == k)

let filterOfJson = (j: option<JSON.t>): filter => {
  let d = j->Option.flatMap(JSON.Decode.object)->Option.getOr(Dict.make())
  let s = k => d->Dict.get(k)->Option.flatMap(JSON.Decode.string)
  {correlationId: ?s("correlationId"), msgId: ?s("msgId"), view: ?s("view"), key: ?s("key")}
}
