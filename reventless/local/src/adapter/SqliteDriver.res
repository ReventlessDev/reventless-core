// Wraps node:sqlite (Node ≥ 22.5). Synchronous API on purpose: it preserves
// the same-tick settling guarantees the in-memory adapters rely on.

type t
type statement

@module("node:sqlite") @new
external openDatabaseSync: string => t = "DatabaseSync"

@module("node:path") external dirname: string => string = "dirname"
type mkdirOpts = {recursive: bool}
@module("node:fs") external mkdirSync: (string, mkdirOpts) => unit = "mkdirSync"

@send external _close: t => unit = "close"
@send external _exec: (t, string) => unit = "exec"
@send external _prepare: (t, string) => statement = "prepare"

// node:sqlite accepts ...positional bound values. Use Function.prototype.apply
// via a small inline helper so the array is splatted without ReScript's
// `@send` syntax accidentally treating `run.apply` as a single property name.
let _runApply: (statement, array<JSON.t>) => unit = %raw(`function(s, a) { return s.run.apply(s, a); }`)
let _getApply: (statement, array<JSON.t>) => Nullable.t<dict<JSON.t>> = %raw(`function(s, a) { return s.get.apply(s, a); }`)
let _allApply: (statement, array<JSON.t>) => array<dict<JSON.t>> = %raw(`function(s, a) { return s.all.apply(s, a); }`)
let _iterateApply: (statement, array<JSON.t>) => Iterator.t<dict<JSON.t>> = %raw(`function(s, a) { return s.iterate.apply(s, a); }`)

let openDb = (~path) => {
  if path !== ":memory:" {
    mkdirSync(dirname(path), {recursive: true})
  }
  let db = openDatabaseSync(path)
  // Connection pragmas. WAL lets readers proceed concurrently with a writer and
  // batches fsyncs into the write-ahead log (a no-op for `:memory:`, which stays
  // on its MEMORY journal); `synchronous=NORMAL` is the safe WAL companion —
  // durable across app crashes, only a power-loss window remains — and cuts the
  // per-commit fsync cost that dominated replay-heavy dev sessions;
  // `busy_timeout` makes a momentarily-locked db wait rather than throw SQLITE_BUSY.
  _exec(db, "PRAGMA journal_mode=WAL")
  _exec(db, "PRAGMA synchronous=NORMAL")
  _exec(db, "PRAGMA busy_timeout=5000")
  db
}
let close = db => _close(db)
let exec = (db, sql) => _exec(db, sql)
let prepare = (db, sql) => _prepare(db, sql)

let run = (stmt, args) => _runApply(stmt, args)
let get = (stmt, args) => _getApply(stmt, args)->Nullable.toOption
let all = (stmt, args) => _allApply(stmt, args)
let iterate = (stmt, args) => _iterateApply(stmt, args)

let transaction = (db, fn) => {
  exec(db, "BEGIN")
  try {
    let result = fn()
    exec(db, "COMMIT")
    result
  } catch {
  | exn =>
    // Roll back, but never let a failing ROLLBACK replace the original error —
    // the original is the diagnostic one; a rollback failure (e.g. no active
    // transaction) would otherwise mask it.
    try exec(db, "ROLLBACK") catch {
    | _ => ()
    }
    throw(exn)
  }
}
