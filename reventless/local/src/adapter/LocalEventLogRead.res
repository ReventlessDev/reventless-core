// One read across every event log of the local platform, newest first.
//
// Each storage registers how to read its log backwards from a position; this
// module merges the logs by the time each event was recorded, ties broken by
// plugin, log and position, without a new column in any store. The cursor holds
// every log's own position, so a page continues exactly where the last one
// stopped while events are appended: what is appended after the first page is
// newer than all of it, and is seen on the event tap, joined by log and position.
//
// The same positions go on the tap's lines: a storage notes each event's
// position as it appends it, and the bus takes the note when it publishes the
// event (`note` / `take`).

type logKind =
  | Aggregate
  | Dcb

/** Where a backwards read of one log starts. */
type bound =
  | Below(float)
  | AtMost(float)

/** One stored event, as a log's reader returns it. `position` is the log's own:
    an aggregate log's row id (or its insertion number in memory), a DCB log's
    position. */
type stored = {
  log: string,
  position: float,
  eventType: string,
  entityId?: string,
  tags: array<Reventless.DcbTag.tag>,
  payload: JSON.t,
  meta: JSON.t,
  recordedAt: string,
}

// The stored event is flat (`Message.storedEventToFlatJson`): meta's fields sit
// beside `event`, `data` and `recordedAt`. The meta is put back together for a
// reader that wants it whole.
let metaOfFlat = (flat: dict<JSON.t>): JSON.t =>
  ReventlessCore.Message.metaKeys
  ->Array.filterMap(k => flat->Dict.get(k)->Option.map(v => (k, v)))
  ->Dict.fromArray
  ->JSON.Encode.object

/** One stored aggregate event as the cross-log read takes it. */
let storedOfFlat = (~log: string, ~position: float, ~entityId: string, payload: JSON.t): stored => {
  let flat = payload->JSON.Decode.object->Option.getOr(Dict.make())
  let str = k => flat->Dict.get(k)->Option.flatMap(JSON.Decode.string)
  let meta = metaOfFlat(flat)
  {
    log,
    position,
    eventType: str("event")->Option.getOr("unknown"),
    entityId,
    tags: [],
    payload: flat->Dict.get("data")->Option.getOr(JSON.Encode.null),
    meta,
    // Every stored event has its own; producer time is the fallback for one
    // written before it did.
    recordedAt: switch str("recordedAt") {
    | Some(t) => t
    | None => str("time")->Option.getOr("")
    },
  }
}

let numberOf = (v: option<JSON.t>): float =>
  switch v {
  | Some(JSON.Number(n)) => n
  | Some(JSON.String(s)) => s->Float.fromString->Option.getOr(0.)
  | _ => 0.
  }

/** Reads at most `limit` events of one log, newest first, from `bound` (from its
    newest event when `None`), narrowed to one correlation id when given. */
type readBack = (
  ~bound: option<bound>,
  ~limit: int,
  ~correlationId: option<string>,
) => promise<array<stored>>

type registered = {kind: logKind, readBack: readBack}

let readers: dict<registered> = Dict.make()
let pluginOfLog: dict<string> = Dict.make()

let register = (~log: string, ~kind: logKind, readBack: readBack) =>
  readers->Dict.set(log, {kind, readBack})

/** Names the plugin a log belongs to. Logs of the platform itself have none. */
let notePlugin = (~log: string, ~plugin: string) => pluginOfLog->Dict.set(log, plugin)

let pluginOf = (log: string): option<string> => pluginOfLog->Dict.get(log)

let logs = (): array<string> => readers->Dict.keysToArray->Array.toSorted(String.compare)

let positionToString = (p: float): string => p->Float.toString

// ─── Positions of events on their way to the tap ─────────────────────────────

// Bounded: a note nobody takes (an event appended and never published) must not
// stay forever.
let maxNotes = 10_000
let notes: Map.t<string, (string, float)> = Map.make()

let note = (~log: string, ~msgId: string, ~position: float) => {
  notes->Map.set(msgId, (log, position))
  if notes->Map.size > maxNotes {
    switch notes->Map.keys->Iterator.next {
    | {done: false, value: Some(oldest)} =>
      let _ = notes->Map.delete(oldest)
    | _ => ()
    }
  }
}

/** The log and position noted for this message, removed as it is read. */
let take = (msgId: string): option<(string, float)> =>
  switch notes->Map.get(msgId) {
  | Some(_) as found =>
    let _ = notes->Map.delete(msgId)
    found
  | None => None
  }

/** Test seam: forgets every reader, plugin and note. */
let resetForTests = () => {
  readers->Dict.keysToArray->Array.forEach(k => readers->Dict.delete(k))
  pluginOfLog->Dict.keysToArray->Array.forEach(k => pluginOfLog->Dict.delete(k))
  notes->Map.clear
}

// ─── Records ─────────────────────────────────────────────────────────────────

type record = {
  plugin?: string,
  log: string,
  position: string,
  eventType: string,
  entityId?: string,
  tags: array<Reventless.DcbTag.tag>,
  payload: JSON.t,
  meta: JSON.t,
  recordedAt: string,
}

let recordToJson = (r: record): JSON.t =>
  [
    ("log", JSON.Encode.string(r.log)),
    ("position", JSON.Encode.string(r.position)),
    ("eventType", JSON.Encode.string(r.eventType)),
    (
      "tags",
      r.tags
      ->Array.map(t =>
        Dict.fromArray([
          ("key", JSON.Encode.string(t.key)),
          ("value", JSON.Encode.string(t.value)),
        ])->JSON.Encode.object
      )
      ->JSON.Encode.array,
    ),
    ("payload", r.payload),
    ("meta", r.meta),
    ("recordedAt", JSON.Encode.string(r.recordedAt)),
  ]
  ->Array.concat(r.plugin->Option.mapOr([], p => [("plugin", JSON.Encode.string(p))]))
  ->Array.concat(r.entityId->Option.mapOr([], e => [("entityId", JSON.Encode.string(e))]))
  ->Dict.fromArray
  ->JSON.Encode.object

// ─── Filter ──────────────────────────────────────────────────────────────────

type filter = {
  plugins?: array<string>,
  logs?: array<string>,
  eventTypes?: array<string>,
  entityId?: string,
  tagKey?: string,
  tagValue?: string,
  msgId?: string,
  correlationId?: string,
  causationId?: string,
  user?: string,
  timeFrom?: string,
  timeTo?: string,
}

/** Reads the filter argument of a query. Absent and null fields do not narrow. */
let filterOfJson = (json: option<JSON.t>): filter => {
  let d = json->Option.flatMap(JSON.Decode.object)->Option.getOr(Dict.make())
  let s = k => d->Dict.get(k)->Option.flatMap(JSON.Decode.string)
  let a = k =>
    d
    ->Dict.get(k)
    ->Option.flatMap(JSON.Decode.array)
    ->Option.map(items => items->Array.filterMap(JSON.Decode.string))
  {
    plugins: ?a("plugins"),
    logs: ?a("logs"),
    eventTypes: ?a("eventTypes"),
    entityId: ?s("entityId"),
    tagKey: ?s("tagKey"),
    tagValue: ?s("tagValue"),
    msgId: ?s("msgId"),
    correlationId: ?s("correlationId"),
    causationId: ?s("causationId"),
    user: ?s("user"),
    timeFrom: ?s("timeFrom"),
    timeTo: ?s("timeTo"),
  }
}

let metaString = (meta: JSON.t, key: string): option<string> =>
  meta
  ->JSON.Decode.object
  ->Option.flatMap(d => d->Dict.get(key))
  ->Option.flatMap(JSON.Decode.string)

let selectsLog = (f: filter, ~log: string, ~plugin: option<string>): bool =>
  f.logs->Option.mapOr(true, logs => logs->Array.includes(log)) &&
    f.plugins->Option.mapOr(true, plugins =>
      plugin->Option.mapOr(false, p => plugins->Array.includes(p))
    )

let matches = (f: filter, r: stored): bool => {
  let equalsMeta = (wanted: option<string>, key) =>
    wanted->Option.mapOr(true, w => metaString(r.meta, key) == Some(w))
  let tagMatch = switch (f.tagKey, f.tagValue) {
  | (Some(k), Some(v)) => r.tags->Array.some(t => t.key == k && t.value == v)
  | (Some(k), None) => r.tags->Array.some(t => t.key == k)
  | (None, Some(v)) => r.tags->Array.some(t => t.value == v)
  | (None, None) => true
  }
  let entityMatch = switch f.entityId {
  | Some(id) => r.entityId == Some(id) || r.tags->Array.some(t => t.value == id)
  | None => true
  }
  tagMatch &&
  entityMatch &&
  f.eventTypes->Option.mapOr(true, types => types->Array.includes(r.eventType)) &&
  equalsMeta(f.msgId, "msgId") &&
  equalsMeta(f.correlationId, "correlationId") &&
  equalsMeta(f.causationId, "causationId") &&
  equalsMeta(f.user, "user") &&
  f.timeFrom->Option.mapOr(true, from => r.recordedAt >= from) &&
  f.timeTo->Option.mapOr(true, to_ => r.recordedAt <= to_)
}

// ─── Cursor ──────────────────────────────────────────────────────────────────

/** Where one log stands in a paged read. */
type logState =
  // Read the log from here on the next page.
  | Until(bound)
  // Nothing left in this log for this read.
  | Done

@val external btoa: string => string = "btoa"
@val external atob: string => string = "atob"

// URL-safe, so a cursor can travel in a query string as it is.
let toBase64Url = (s: string) =>
  s->btoa->String.replaceAll("+", "-")->String.replaceAll("/", "_")->String.replaceAll("=", "")

let fromBase64Url = (s: string) => {
  let b = s->String.replaceAll("-", "+")->String.replaceAll("_", "/")
  atob(b ++ String.repeat("=", mod(4 - mod(b->String.length, 4), 4)))
}

let encodeCursor = (states: array<(string, logState)>): string =>
  states
  ->Array.map(((log, state)) => (
    log,
    switch state {
    | Until(Below(p)) => Dict.fromArray([("below", JSON.Encode.float(p))])->JSON.Encode.object
    | Until(AtMost(p)) => Dict.fromArray([("atMost", JSON.Encode.float(p))])->JSON.Encode.object
    | Done => JSON.Encode.string("done")
    },
  ))
  ->Dict.fromArray
  ->JSON.Encode.object
  ->JSON.stringify
  ->toBase64Url

/** `None` for a cursor that is not one of ours. */
let decodeCursor = (cursor: string): option<dict<logState>> =>
  switch cursor->fromBase64Url->JSON.parseOrThrow->JSON.Decode.object {
  | Some(d) =>
    let out = Dict.make()
    d
    ->Dict.toArray
    ->Array.forEach(((log, v)) =>
      switch v {
      | JSON.String("done") => out->Dict.set(log, Done)
      | JSON.Object(o) =>
        switch (
          o->Dict.get("below")->Option.flatMap(JSON.Decode.float),
          o->Dict.get("atMost")->Option.flatMap(JSON.Decode.float),
        ) {
        | (Some(p), _) => out->Dict.set(log, Until(Below(p)))
        | (None, Some(p)) => out->Dict.set(log, Until(AtMost(p)))
        | (None, None) => ()
        }
      | _ => ()
      }
    )
    Some(out)
  | None => None
  | exception _ => None
  }

// ─── The merged read ─────────────────────────────────────────────────────────

type source = {
  log: string,
  plugin?: string,
  reader: registered,
  // Where the next fetch starts; `None` before the first.
  mutable scan: option<bound>,
  mutable fetched: bool,
  mutable exhausted: bool,
  // Matching records fetched and not yet taken, newest first.
  mutable buffer: array<stored>,
  // What the cursor says for this log after what was taken.
  mutable state: logState,
}

type page = {
  edges: array<(record, string)>,
  hasNextPage: bool,
  endCursor?: string,
}

let defaultPageSize = 50
let maxPageSize = 1000

let toRecord = (s: source, r: stored): record => {
  plugin: ?s.plugin,
  log: r.log,
  position: r.position->positionToString,
  eventType: r.eventType,
  entityId: ?r.entityId,
  tags: r.tags,
  payload: r.payload,
  meta: r.meta,
  recordedAt: r.recordedAt,
}

/** Newer first; at the same time, by plugin, then log, then the higher position. */
let newerFirst = ((sa: source, a: stored), (sb: source, b: stored)): float =>
  if a.recordedAt != b.recordedAt {
    a.recordedAt > b.recordedAt ? -1. : 1.
  } else {
    let pa = sa.plugin->Option.getOr("")
    let pb = sb.plugin->Option.getOr("")
    if pa != pb {
      String.compare(pa, pb)
    } else if sa.log != sb.log {
      String.compare(sa.log, sb.log)
    } else {
      b.position -. a.position
    }
  }

/** One page of every selected log's events, newest first. `after` is the
    `endCursor` (or an edge's cursor) of the page before. */
let read = async (~filter: filter, ~first: option<int>=?, ~after: option<string>=?): page => {
  let pageSize = first->Option.getOr(defaultPageSize)->Math.Int.max(0)->Math.Int.min(maxPageSize)
  let incoming = after->Option.flatMap(decodeCursor)
  let sources = logs()->Array.filterMap(log => {
    let plugin = pluginOf(log)
    switch (readers->Dict.get(log), selectsLog(filter, ~log, ~plugin)) {
    | (Some(reader), true) =>
      let start = switch incoming {
      // A log the first page did not know was created since: its events are
      // all newer than that page.
      | Some(states) => states->Dict.get(log)->Option.getOr(Done)
      | None => Until(AtMost(infinity))
      }
      switch start {
      | Done => None
      | Until(bound) =>
        Some({
          log,
          ?plugin,
          reader,
          scan: incoming->Option.isSome ? Some(bound) : None,
          fetched: false,
          exhausted: false,
          buffer: [],
          state: incoming->Option.isSome ? start : Done,
        })
      }
    | _ => None
    }
  })
  let batch = Math.Int.max(pageSize + 1, 50)

  let fetch = async (s: source) => {
    let rows = await s.reader.readBack(
      ~bound=s.scan,
      ~limit=batch,
      ~correlationId=filter.correlationId,
    )

    // The first page pins each log at its newest event, so events appended while
    // a reader pages are left to the tap rather than shifting the pages.
    if !s.fetched {
      s.fetched = true
      if incoming->Option.isNone {
        s.state = switch rows->Array.get(0) {
        | Some(newest) => Until(AtMost(newest.position))
        | None => Done
        }
      }
    }
    switch rows->Array.at(-1) {
    | Some(oldest) => s.scan = Some(Below(oldest.position))
    | None => ()
    }
    if rows->Array.length < batch {
      s.exhausted = true
    }
    s.buffer = s.buffer->Array.concat(rows->Array.filter(r => matches(filter, r)))
  }

  let rec headOf = async (s: source): option<stored> =>
    switch s.buffer->Array.get(0) {
    | Some(_) as head => head
    | None if s.exhausted => None
    | None =>
      await fetch(s)
      await headOf(s)
    }

  let newest = async (): option<(source, stored)> => {
    let heads = []
    for i in 0 to sources->Array.length - 1 {
      let s = sources->Array.getUnsafe(i)
      switch await headOf(s) {
      | Some(r) => heads->Array.push((s, r))
      | None => ()
      }
    }
    heads->Array.toSorted(newerFirst)->Array.get(0)
  }

  let stateNow = () => sources->Array.map(s => (s.log, s.state))
  // A log the cursor does not name is finished: the next page skips it.
  let cursorNow = () => encodeCursor(stateNow())

  let edges = []
  let stop = ref(false)
  while !stop.contents && edges->Array.length < pageSize {
    switch await newest() {
    | None => stop := true
    | Some((s, r)) =>
      s.buffer = s.buffer->Array.slice(~start=1, ~end=s.buffer->Array.length)
      s.state = s.exhausted && s.buffer->Array.length == 0 ? Done : Until(Below(r.position))
      edges->Array.push((toRecord(s, r), cursorNow()))
    }
  }
  let hasNextPage = (await newest())->Option.isSome
  // Logs that ran out without giving this page anything are finished too.
  sources->Array.forEach(s =>
    if s.exhausted && s.buffer->Array.length == 0 {
      s.state = Done
    }
  )
  {
    edges,
    hasNextPage,
    endCursor: ?(edges->Array.length > 0 || incoming->Option.isSome ? Some(cursorNow()) : None),
  }
}
