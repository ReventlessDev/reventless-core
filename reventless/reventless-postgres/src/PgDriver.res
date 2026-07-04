// node-postgres (`pg`) binding. See PgDriver.resi for the contract.

type pool
type client

type poolConfig = {
  connectionString: string,
  max?: int,
}

// pg is CJS (`module.exports = { Pool, Client, ... }`); Node's ESM interop
// exposes `Pool` as a named import.
@module("pg") @new external makePool: poolConfig => pool = "Pool"

@send external _end: pool => promise<unit> = "end"
let endPool = pool => _end(pool)

// pg's `query` resolves to a result object; `.rows` is the payload we want.
type queryResult = {rows: array<dict<JSON.t>>}

@send external _query: (pool, string, array<JSON.t>) => promise<queryResult> = "query"
@send external _queryText: (pool, string) => promise<queryResult> = "query"
@send external _connect: pool => promise<client> = "connect"
@send external _release: client => unit = "release"
@send external _clientQuery: (client, string, array<JSON.t>) => promise<queryResult> = "query"
@send external _clientQueryText: (client, string) => promise<queryResult> = "query"

let query = async (pool, sql, params) => (await _query(pool, sql, params)).rows

let queryOne = async (pool, sql, params) =>
  (await _query(pool, sql, params)).rows->Array.get(0)

let exec = async (pool, sql) => {
  let _ = await _queryText(pool, sql)
}

let queryOn = async (client, sql, params) => (await _clientQuery(client, sql, params)).rows
let execOn = async (client, sql) => {
  let _ = await _clientQueryText(client, sql)
}

let transaction = async (pool, fn) => {
  let client = await _connect(pool)
  try {
    let _ = await _clientQueryText(client, "BEGIN")
    let result = await fn(client)
    let _ = await _clientQueryText(client, "COMMIT")
    _release(client)
    result
  } catch {
  | exn =>
    // Roll back and release, but never let a failing ROLLBACK mask the original
    // error (the original is the diagnostic one). Always return the connection.
    try {
      let _ = await _clientQueryText(client, "ROLLBACK")
    } catch {
    | _ => ()
    }
    _release(client)
    throw(exn)
  }
}

// LISTEN/NOTIFY on a dedicated connection. `notification` events carry
// `{channel, payload}`; we forward the payload string.
type notification = {payload: Nullable.t<string>}
@send
external _onNotification: (client, @as("notification") _, notification => unit) => unit = "on"

let listen = async (pool, ~channel, ~onNotify) => {
  let client = await _connect(pool)
  client->_onNotification(n =>
    switch n.payload->Nullable.toOption {
    | Some(p) => onNotify(p)
    | None => ()
    }
  )
  // Channel identifiers can't be parameterised; the caller supplies a
  // framework-controlled name (`dcb_<log>`), never user input.
  let _ = await _clientQueryText(client, `LISTEN "${channel}"`)
  client
}

let unlisten = async (client, ~channel) => {
  try {
    let _ = await _clientQueryText(client, `UNLISTEN "${channel}"`)
  } catch {
  | _ => ()
  }
  _release(client)
}
