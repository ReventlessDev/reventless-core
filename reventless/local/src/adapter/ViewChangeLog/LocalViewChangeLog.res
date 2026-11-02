// Every row change the local platform makes, kept and read back by flow, event, view or row:
// a tool that missed a change live reads it here. In the SQLite store when the platform runs
// on one, else in memory for as long as it runs (Postgres included, whose store is not
// this machine's). Each change is the tap's `viewChange` line, so live and stored read alike.

module ViewChange = ReventlessCore.ViewChange

/** A change as a page lists it: the tap's line, and the cursor to read on after it. */
type node = {item: JSON.t, cursor: string}

type page = {records: array<node>, hasNextPage: bool, endCursor?: string}

let sqliteReady = ref(None)

/** The SQLite store when the platform runs on one, its table made once. */
let sqlite = () =>
  switch BackendState.getSqliteDb() {
  | Some(db) =>
    if sqliteReady.contents !== Some(db) {
      ViewChangeLogStorage_Sqlite.ensureSchema(db)
      sqliteReady := Some(db)
    }
    Some(db)
  | None => None
  }

let nextSeq = ref(0)

let record = (c: ViewChange.t) => {
  let item = LocalTapLines.viewChangeLine(c)->JSON.parseOrThrow
  let entry: ViewChangeLogEntry.t = {
    seq: 0,
    flow: ?c.correlationId,
    view: c.view,
    key: c.key,
    msgIds: c.sources->Array.map(s => s.msgId),
    item,
  }
  switch sqlite() {
  | Some(db) => ViewChangeLogStorage_Sqlite.append(db, entry)
  | None =>
    nextSeq := nextSeq.contents + 1
    ViewChangeLogStorage_InMemory.append({...entry, seq: nextSeq.contents})
  }
}

/** A page of the changes matching the filter, newest first; `after` is a page's `endCursor`. */
let read = (~filter: ViewChangeLogEntry.filter, ~first=100, ~after: option<string>=?): page => {
  let before = after->Option.flatMap(a => Int.fromString(a))
  // One more than asked, to know whether there is a next page.
  let rows = switch sqlite() {
  | Some(db) => ViewChangeLogStorage_Sqlite.read(db, ~filter, ~before, ~first=first + 1)
  | None => ViewChangeLogStorage_InMemory.read(~filter, ~before, ~first=first + 1)
  }
  let shown = rows->Array.slice(~start=0, ~end=first)
  let hasNextPage = rows->Array.length > first
  {
    records: shown->Array.map(e => {item: e.item, cursor: e.seq->Int.toString}),
    hasNextPage,
    endCursor: ?(hasNextPage ? shown->Array.at(-1)->Option.map(e => e.seq->Int.toString) : None),
  }
}

let removal: ref<option<unit => unit>> = ref(None)

/** Starts keeping every row change, once per process. A change that cannot be kept is logged
    and passed over: the row is already written. */
let install = () =>
  if removal.contents->Option.isNone {
    let log = ReventlessCore.Logger.fromEnv()
    removal :=
      Some(
        ViewChange.register(c =>
          try record(c) catch {
          | exn =>
            log.warn(
              ~comp="ViewChangeLog",
              `a row change of ${c.view} was not kept: ${exn
                ->JsExn.fromException
                ->Option.flatMap(JsExn.message)
                ->Option.getOr("unknown")}`,
            )
          }
        ),
      )
  }

/** Test seam: stops keeping them and forgets the in-memory ones. */
let resetForTests = () => {
  removal.contents->Option.forEach(remove => remove())
  removal := None
  ViewChangeLogStorage_InMemory.clear()
  nextSeq := 0
  sqliteReady := None
}
