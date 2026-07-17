// Sealed wrapper around node-postgres (`pg`).
//
// Unlike SqliteDriver (node:sqlite, synchronous), every operation here is
// asynchronous — there is no synchronous Postgres client in Node. Storage
// makers stay synchronous (they only close over a `pool`); the async cost lands
// where the adapter operations already are (`append`/`read` return promises).
// Schema setup (`PgSchema.ensureSchema`) is therefore a distinct async step run
// once before any maker, not an inline `ensureSchema` inside the maker.
//
// The interface is kept tight so a different driver could be dropped in later
// without callers changing.

type pool
type client

// TLS options. Required for RDS/managed Postgres (PG15+ defaults to
// `rds.force_ssl=1`). `rejectUnauthorized: false` encrypts without CA
// verification.
type sslConfig = {rejectUnauthorized: bool}

// Invoked by pg per physical connection, so a rotated secret is picked up on the
// next new connection without rebuilding the pool.
type passwordProvider = unit => promise<string>

type poolConfig = {
  // Supply either a full `connectionString` (local/dev) or the discrete fields
  // (AWS adapter — password comes from a Secrets Manager provider that can't be
  // baked into a static string).
  connectionString?: string,
  host?: string,
  port?: int,
  database?: string,
  user?: string,
  password?: passwordProvider,
  ssl?: sslConfig,
  // Upper bound on pooled connections. Defaults to pg's own default (10).
  max?: int,
}

let makePool: poolConfig => pool
let endPool: pool => promise<unit>

// Parameterised query (extended protocol — exactly one statement). Returns the
// result rows. Postgres returns `bigint`/`xid8` as strings, `jsonb` already
// parsed, and `text[]` as a JS array — all directly usable as `JSON.t`.
let query: (pool, string, array<JSON.t>) => promise<array<dict<JSON.t>>>

// Parameterised query returning the first row, or None.
let queryOne: (pool, string, array<JSON.t>) => promise<option<dict<JSON.t>>>

// Simple-protocol statement with no parameters — allows multi-statement DDL and
// dollar-quoted function bodies. Used by PgSchema.
let exec: (pool, string) => promise<unit>

// Run `fn` inside BEGIN/COMMIT on a single checked-out connection. Rolls back on
// any rejected promise or thrown exception, then always releases the connection.
// Transaction-scoped advisory locks require this single-connection guarantee.
let transaction: (pool, client => promise<'a>) => promise<'a>

// Same as `query`, but on an explicit transaction connection.
let queryOn: (client, string, array<JSON.t>) => promise<array<dict<JSON.t>>>
let execOn: (client, string) => promise<unit>

// Open a dedicated long-lived connection issuing `LISTEN <channel>`, invoking
// `onNotify` with each notification payload. The returned client is caller-owned
// (call `unlisten` to `UNLISTEN` + release). Used by the change feed (Phase D).
let listen: (pool, ~channel: string, ~onNotify: string => unit) => promise<client>
let unlisten: (client, ~channel: string) => promise<unit>
