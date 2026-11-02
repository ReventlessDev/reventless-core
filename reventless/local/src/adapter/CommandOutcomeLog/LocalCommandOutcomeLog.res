// What became of every command the local platform handled, kept and read back by flow or by
// the command's message id: a tool that missed an outcome live reads it here. Stored as the
// row changes are (`LocalViewChangeLog`), each as the tap's `commandOutcome` line.

module Outcome = ReventlessCore.CommandTopic_Helpers

type page = LocalViewChangeLog.page

let sqliteReady = ref(None)

/** The SQLite store when the platform runs on one, its table made once. */
let sqlite = () =>
  switch BackendState.getSqliteDb() {
  | Some(db) =>
    if sqliteReady.contents !== Some(db) {
      CommandOutcomeLogStorage_Sqlite.ensureSchema(db)
      sqliteReady := Some(db)
    }
    Some(db)
  | None => None
  }

let nextSeq = ref(0)

let record = (r: Outcome.commandOutcomeReport) => {
  let entry: CommandOutcomeLogEntry.t = {
    seq: 0,
    flow: ?r.correlationId,
    msgId: r.reference,
    item: LocalTapLines.outcomeLine(r)->JSON.parseOrThrow,
  }
  switch sqlite() {
  | Some(db) => CommandOutcomeLogStorage_Sqlite.append(db, entry)
  | None =>
    nextSeq := nextSeq.contents + 1
    CommandOutcomeLogStorage_InMemory.append({...entry, seq: nextSeq.contents})
  }
}

/** A page of the outcomes matching the filter, newest first; `after` is a page's `endCursor`. */
let read = (~filter: CommandOutcomeLogEntry.filter, ~first=100, ~after: option<string>=?): page => {
  let before = after->Option.flatMap(a => Int.fromString(a))
  // One more than asked, to know whether there is a next page.
  let rows = switch sqlite() {
  | Some(db) => CommandOutcomeLogStorage_Sqlite.read(db, ~filter, ~before, ~first=first + 1)
  | None => CommandOutcomeLogStorage_InMemory.read(~filter, ~before, ~first=first + 1)
  }
  let shown = rows->Array.slice(~start=0, ~end=first)
  let hasNextPage = rows->Array.length > first
  {
    records: shown->Array.map(e => {LocalViewChangeLog.item: e.item, cursor: e.seq->Int.toString}),
    hasNextPage,
    endCursor: ?(hasNextPage ? shown->Array.at(-1)->Option.map(e => e.seq->Int.toString) : None),
  }
}

let removal: ref<option<unit => unit>> = ref(None)

/** Starts keeping every outcome, once per process. One that cannot be kept is logged and passed
    over: the command is already decided. */
let install = () =>
  if removal.contents->Option.isNone {
    let log = ReventlessCore.Logger.fromEnv()
    removal :=
      Some(
        Outcome.registerCommandOutcome(r =>
          try record(r) catch {
          | exn =>
            log.warn(
              ~comp="CommandOutcomeLog",
              `the outcome of ${r.reference} was not kept: ${exn
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
  CommandOutcomeLogStorage_InMemory.clear()
  nextSeq := 0
  sqliteReady := None
}
