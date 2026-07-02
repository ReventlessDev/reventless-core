// SQLite-backed QueryDb storage.
//
// One table per registered QueryDb (`qdb_<name>`). Columns:
//   partition_key TEXT
//   sub_key       TEXT
//   item          TEXT (JSON.stringify of the item)
//   expires_at    INTEGER NULL (unix epoch seconds; null = never expires)
//   PRIMARY KEY (partition_key, sub_key)
//
// TTL: every read clause carries `(expires_at IS NULL OR expires_at > <now>)`.
// Lazy expiry — no background sweeper. Expired rows linger on disk until they
// are next read (where they are filtered out) or overwritten by a new save.
//
// GSI: each declared `indexConfig` creates a SQLite index on the JSON column
// using `json_extract(item, '$.<field>')`. Composite keys (`pkFields` /
// `skFields` joined by `pkSep`/`skSep`) become a single computed expression.
// The DynamoDB `projectionType` is recorded for documentation but the SQLite
// covering-index distinction is irrelevant — every column is on the same row.

open ReventlessCore
open Reventless.ReadModel

let tableName = (name: string): string => "qdb_" ++ name->String.replaceAll("-", "_")

// SQL identifier sanitisation — collapse anything outside [A-Za-z0-9_] to _.
// Keeps generated index names predictable and injection-safe.
let sanitizeIdent = (s: string): string =>
  s
  ->String.split("")
  ->Array.map(ch => {
    let code = ch->String.codePointAt(0)->Option.getOr(0)
    let isAlphaNum =
      (code >= 48 && code <= 57) ||
      (code >= 65 && code <= 90) ||
      (code >= 97 && code <= 122) ||
      code == 95
    isAlphaNum ? ch : "_"
  })
  ->Array.join("")

let ensureSchema = (~db, ~table) =>
  db->SqliteDriver.exec(
    `CREATE TABLE IF NOT EXISTS ${table} (partition_key TEXT NOT NULL, sub_key TEXT NOT NULL DEFAULT '', item TEXT NOT NULL, expires_at INTEGER, PRIMARY KEY (partition_key, sub_key))`,
  )

// Best-effort migration for tables created by an earlier (Phase 2) version
// that did not have the expires_at column. Safe no-op when column already
// exists. Wrapped in try/catch since some sqlite versions throw on duplicate.
let ensureExpiresColumn = (~db, ~table) =>
  try db->SqliteDriver.exec(`ALTER TABLE ${table} ADD COLUMN expires_at INTEGER`) catch {
  | _ => ()
  }

// Build the json_extract expression for a single field path.
let jsonField = (field: string): string => `json_extract(item, '$.${field}')`

// Composite-key indexes are concatenations: json_extract(...) || sep || json_extract(...) || ...
let compositeExpr = (fields: array<string>, sep: string): string => {
  let escapedSep = sep->String.replaceAll("'", "''")
  fields->Array.map(jsonField)->Array.join(` || '${escapedSep}' || `)
}

// Determine the index's partition expression and (optional) sort expression.
// Uses pkFields if present, else falls back to idField; same for sub key.
let indexExpressions = (idx: indexConfig): (string, option<string>) => {
  let pkExpr = switch idx.pkFields {
  | Some(fields) if fields->Array.length > 0 =>
    compositeExpr(fields, idx.pkSep->Option.getOr("/"))
  | _ =>
    switch idx.idField {
    | Some(field) => jsonField(field)
    | None => jsonField(idx.index)
    }
  }
  let skExpr = switch idx.skFields {
  | Some(fields) if fields->Array.length > 0 =>
    Some(compositeExpr(fields, idx.skSep->Option.getOr("/")))
  | _ =>
    switch idx.subIdField {
    | Some(field) => Some(jsonField(field))
    | None => None
    }
  }
  (pkExpr, skExpr)
}

// Create one SQLite index per declared GSI. Idempotent via IF NOT EXISTS.
let ensureIndexes = (~db, ~table, ~indexes: array<indexConfig>) =>
  indexes->Array.forEach(idx => {
    let (pkExpr, skExprOpt) = indexExpressions(idx)
    let indexName = `idx_${table}_${sanitizeIdent(idx.index)}`
    let cols = switch skExprOpt {
    | Some(skExpr) => `${pkExpr}, ${skExpr}`
    | None => pkExpr
    }
    db->SqliteDriver.exec(`CREATE INDEX IF NOT EXISTS ${indexName} ON ${table} (${cols})`)
  })

let decodeItem = (row: dict<JSON.t>): JSON.t =>
  switch row->Dict.get("item") {
  | Some(JSON.String(s)) =>
    switch JSON.parseOrThrow(s) {
    | json => json
    | exception _ => JSON.Encode.null
    }
  | _ => JSON.Encode.null
  }

let computeSubKey = (item: JSON.t, subIdField: option<string>): string =>
  switch subIdField {
  | None => ""
  | Some(field) =>
    switch item->JSON.Decode.object {
    | Some(obj) =>
      switch obj->Dict.get(field) {
      | Some(JSON.String(s)) => s
      | _ => ""
      }
    | None => ""
    }
  }

let withId = (item: JSON.t, partitionKey: string): JSON.t =>
  switch item->JSON.Decode.object {
  | Some(obj) =>
    if obj->Dict.get("id")->Option.isSome {
      item
    } else {
      let copy = Dict.make()
      obj->Dict.toArray->Array.forEach(((k, v)) => copy->Dict.set(k, v))
      copy->Dict.set("id", JSON.Encode.string(partitionKey))
      JSON.Encode.object(copy)
    }
  | None => item
  }

type busCallbacks = {
  publishStateChange: (~name: string, ~descriptor: JSON.t) => unit,
  registerQueryDb: (string, QueryDb_Adapter.operations) => unit,
  registerQueryDbScan: (string, unit => array<JSON.t>) => unit,
  registerQueryDbStream: (string, unit => Stream.t<JSON.t, string, unit>) => unit,
  registerQueryDbIndexLookup: (string, (string, string) => array<JSON.t>) => unit,
}

// SQL fragment that excludes expired rows. Uses unix-epoch seconds via
// strftime; SQLite evaluates it on every row, which is fine at dev scale.
let notExpiredClause = "(expires_at IS NULL OR expires_at > strftime('%s','now'))"

let makeStorage = (
  ~db: SqliteDriver.t,
  ~bus: busCallbacks,
  ~name,
  ~indexes: array<indexConfig>,
  ~subIdField: option<string>,
): QueryDb_Adapter.storage => {
  let table = tableName(name)
  ensureSchema(~db, ~table)
  ensureExpiresColumn(~db, ~table)
  ensureIndexes(~db, ~table, ~indexes)

  let upsertStmt = db->SqliteDriver.prepare(
    `INSERT INTO ${table}(partition_key, sub_key, item, expires_at) VALUES(?,?,?,?) ON CONFLICT(partition_key, sub_key) DO UPDATE SET item = excluded.item, expires_at = excluded.expires_at`,
  )
  let selectByPartitionStmt = db->SqliteDriver.prepare(
    `SELECT partition_key, sub_key, item FROM ${table} WHERE partition_key = ? AND ${notExpiredClause} ORDER BY sub_key ASC`,
  )
  let deleteByPartitionStmt = db->SqliteDriver.prepare(
    `DELETE FROM ${table} WHERE partition_key = ?`,
  )
  let deleteBySubKeyStmt = db->SqliteDriver.prepare(
    `DELETE FROM ${table} WHERE partition_key = ? AND sub_key = ?`,
  )
  let scanAllStmt = db->SqliteDriver.prepare(
    `SELECT partition_key, sub_key, item FROM ${table} WHERE ${notExpiredClause} ORDER BY partition_key, sub_key`,
  )

  let rowsFor = (id: string): array<JSON.t> =>
    selectByPartitionStmt
    ->SqliteDriver.all([JSON.Encode.string(id)])
    ->Array.map(decodeItem)

  let rowToItem = (row: dict<JSON.t>): JSON.t => {
    let item = decodeItem(row)
    let partition = switch row->Dict.get("partition_key") {
    | Some(JSON.String(s)) => s
    | _ => ""
    }
    withId(item, partition)
  }

  let allRows = (): array<JSON.t> => scanAllStmt->SqliteDriver.all([])->Array.map(rowToItem)

  // Equality lookup on an indexed JSON field, pushed down to SQLite so the query
  // rides the `json_extract` GSI index (`ensureIndexes`) instead of scanning +
  // parsing every row in the resolver. Statements are prepared once per field and
  // cached. String comparison mirrors the resolver's JS path (which only matched
  // string-typed fields), so results are identical.
  let indexLookupStmts: Dict.t<SqliteDriver.statement> = Dict.make()
  let lookupByField = (field: string, value: string): array<JSON.t> => {
    let stmt = switch indexLookupStmts->Dict.get(field) {
    | Some(s) => s
    | None =>
      // Escape single quotes in the JSON path literal so an odd field name can't
      // break out of the string (bound `?` already covers the value).
      let escapedField = field->String.replaceAll("'", "''")
      let s = db->SqliteDriver.prepare(
        `SELECT partition_key, sub_key, item FROM ${table} WHERE json_extract(item, '$.${escapedField}') = ? AND ${notExpiredClause}`,
      )
      indexLookupStmts->Dict.set(field, s)
      s
    }
    stmt->SqliteDriver.all([JSON.Encode.string(value)])->Array.map(rowToItem)
  }

  let saveOne = (id: string, state: JSON.t, ttl: option<int>) => {
    let subKey = computeSubKey(state, subIdField)
    let expiresAt = switch ttl {
    | Some(t) => JSON.Encode.int(t)
    | None => JSON.Encode.null
    }
    upsertStmt->SqliteDriver.run([
      JSON.Encode.string(id),
      JSON.Encode.string(subKey),
      JSON.Encode.string(JSON.stringify(state)),
      expiresAt,
    ])
  }

  let load: QueryDb.load<string, JSON.t> = async id => Ok(rowsFor(id))

  let loadStream: QueryDb.loadStream<string, JSON.t> = id => rowsFor(id)->Stream.fromIterable

  // Entity key matches the AWS StateTopic Lambda output (Phase 1):
  // single-key tables → partition value; composite tables → `pk-sk`.
  let entityKeyFor = (id: string, subKey: string): string =>
    switch subIdField {
    | Some(_) => id ++ "-" ++ subKey
    | None => id
    }

  let publishUpdated = (id: string, state: JSON.t) => {
    let subKey = computeSubKey(state, subIdField)
    let descriptor = LocalBus.makeStateChangeDescriptor(
      ~changeKind="Updated",
      ~id=entityKeyFor(id, subKey),
      ~state=Some(state),
    )
    bus.publishStateChange(~name, ~descriptor)
  }

  let publishRemoved = (id: string, subKey: string) => {
    let descriptor = LocalBus.makeStateChangeDescriptor(
      ~changeKind="Removed",
      ~id=entityKeyFor(id, subKey),
      ~state=None,
    )
    bus.publishStateChange(~name, ~descriptor)
  }

  // Read all (id, sub_key) tuples that a partition-level delete would remove.
  let rowKeysForPartition = (id: string): array<string> =>
    selectByPartitionStmt
    ->SqliteDriver.all([JSON.Encode.string(id)])
    ->Array.map(row =>
      switch row->Dict.get("sub_key") {
      | Some(JSON.String(s)) => s
      | _ => ""
      }
    )

  let save: QueryDb.save<string, JSON.t> = async (id, state, _saveMode, ttl) => {
    saveOne(id, state, ttl)
    publishUpdated(id, state)
    Ok()
  }

  let saveBatch: QueryDb.saveBatch<string, JSON.t> = async batch => {
    db->SqliteDriver.transaction(() =>
      batch->Array.forEach(((id, state, ttl)) => saveOne(id, state, ttl))
    )
    batch->Array.forEach(((id, state, _)) => publishUpdated(id, state))
    Ok()
  }

  // Mirror DynamoDB's `ADD #fieldName :inc` on key {id}: read the counter field
  // on the partition-key item (counters are single-state, sub_key=""), add `inc`,
  // upsert, and return the NEW total. The previous `Ok(inc)` echoed the increment
  // and never persisted, so the total was wrong and `loadStream` never saw it.
  let count: QueryDb.count<string> = async (id, fieldName, inc) => {
    let existing = rowsFor(id)->Array.get(0)->Option.flatMap(JSON.Decode.object)
    let current =
      existing
      ->Option.flatMap(o => o->Dict.get(fieldName))
      ->Option.flatMap(JSON.Decode.float)
      ->Option.mapOr(0, Float.toInt)
    let next = current + inc
    let obj = Dict.make()
    switch existing {
    | Some(o) => o->Dict.toArray->Array.forEach(((k, v)) => obj->Dict.set(k, v))
    | None => ()
    }
    obj->Dict.set("id", JSON.Encode.string(id))
    obj->Dict.set(fieldName, JSON.Encode.int(next))
    let newItem = JSON.Encode.object(obj)
    saveOne(id, newItem, None)
    publishUpdated(id, newItem)
    Ok(next)
  }

  let deleteOne = (id: string, subIdOpt) =>
    switch subIdOpt {
    | None => deleteByPartitionStmt->SqliteDriver.run([JSON.Encode.string(id)])
    | Some((_, subValue)) =>
      deleteBySubKeyStmt->SqliteDriver.run([
        JSON.Encode.string(id),
        JSON.Encode.string(subValue),
      ])
    }

  let delete: QueryDb.delete<string> = async (id, subIdOpt) => {
    let removedSubKeys = switch subIdOpt {
    | None => rowKeysForPartition(id)
    | Some((_, subValue)) => [subValue]
    }
    deleteOne(id, subIdOpt)
    removedSubKeys->Array.forEach(sk => publishRemoved(id, sk))
    Ok()
  }

  let deleteBatch: QueryDb.deleteBatch<string> = async ids => {
    let removed: array<(string, string)> = []
    ids->Array.forEach(((id, subIdOpt)) => {
      switch subIdOpt {
      | None => rowKeysForPartition(id)->Array.forEach(sk => removed->Array.push((id, sk)))
      | Some((_, subValue)) => removed->Array.push((id, subValue))
      }
    })
    db->SqliteDriver.transaction(() => ids->Array.forEach(((id, s)) => deleteOne(id, s)))
    removed->Array.forEach(((id, sk)) => publishRemoved(id, sk))
    Ok()
  }

  let ops: QueryDb_Adapter.operations = {
    load,
    loadStream,
    save,
    saveBatch,
    count,
    delete,
    deleteBatch,
  }

  bus.registerQueryDb(name, ops)
  bus.registerQueryDbScan(name, () => allRows())
  bus.registerQueryDbStream(name, () => allRows()->Stream.fromIterable)
  bus.registerQueryDbIndexLookup(name, lookupByField)

  {
    resources: [],
    dataSourceName: ""->Pulumi.Output.make,
    operations: Pulumi.Output.make(ops),
  }
}

module Make = (Bus: LocalBus.T, DbProvider: {let db: SqliteDriver.t}) => {
  type api = unit
  type role = unit

  let busCallbacks = {
    publishStateChange: Bus.publishStateChange,
    registerQueryDb: Bus.registerQueryDb,
    registerQueryDbScan: Bus.registerQueryDbScan,
    registerQueryDbStream: Bus.registerQueryDbStream,
    registerQueryDbIndexLookup: Bus.registerQueryDbIndexLookup,
  }

  let make: QueryDb_Adapter.storageMaker<unit, unit> = (
    ~name,
    ~indexes,
    ~subIdField=?,
    ~ttl as _=?,
    ~api as _,
    ~apiRole as _,
    ~opts as _,
  ) => makeStorage(~db=DbProvider.db, ~bus=busCallbacks, ~name, ~indexes, ~subIdField)
}
