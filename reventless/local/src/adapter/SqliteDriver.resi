// Sealed wrapper around an embedded SQLite driver.
//
// Currently uses Node's built-in node:sqlite (Node ≥ 22.5). The interface is
// kept tight enough that other drivers (better-sqlite3, bun:sqlite) can be
// dropped in later without callers changing.

type t
type statement

let openDb: (~path: string) => t
let close: t => unit

// Execute one or more statements without parameter binding (DDL, PRAGMA, BEGIN/COMMIT).
let exec: (t, string) => unit

let prepare: (t, string) => statement

// Bind positional parameters and run a non-SELECT statement.
let run: (statement, array<JSON.t>) => unit

// Bind and return the first row, or None.
let get: (statement, array<JSON.t>) => option<dict<JSON.t>>

// Bind and return all rows.
let all: (statement, array<JSON.t>) => array<dict<JSON.t>>

// Bind and return rows lazily as a JS iterator. Caller is responsible for draining.
let iterate: (statement, array<JSON.t>) => Iterator.t<dict<JSON.t>>

// Run a function inside BEGIN/COMMIT. Rolls back on any thrown exception.
let transaction: (t, unit => 'a) => 'a
