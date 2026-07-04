// Postgres-backed QueryDb storage — JSONB document tables, one per read model.
//
// Implements the clean QueryDb_Adapter.storageMaker (the shape
// QueryDbStorage_DynamoDb implements): no in-process bus. The reventless-local
// bridge that publishes state-changes to live GraphQL subscriptions wraps this
// at integration time (Phase E), the way QueryDbStorage_Sqlite wraps its data
// access today.
//
// Table `qdb_<name>`: partition_key text, sub_key text, item jsonb, expires_at
// double precision (unix epoch seconds; null = never), PRIMARY KEY
// (partition_key, sub_key). `item jsonb` returns already parsed. TTL is lazy —
// every read carries `(expires_at IS NULL OR expires_at > epoch_now)`.
//
// GSI: each declared indexConfig becomes an expression index on `item->>'field'`
// (composite keys concatenated with the configured separator). projectionType is
// irrelevant in a relational store (every column is on the same row).

open ReventlessCore
open Reventless.ReadModel

let tableName = (name: string): string => "qdb_" ++ name->String.replaceAll("-", "_")

// Collapse anything outside [A-Za-z0-9_] to _ — predictable, injection-safe idents.
let sanitizeIdent = (s: string): string =>
  s->String.replaceRegExp(%re("/[^A-Za-z0-9_]/g"), "_")

let notExpiredClause = "(expires_at IS NULL OR expires_at > extract(epoch from now()))"

// JSONB text extraction for a single top-level field.
let jsonField = (field: string): string =>
  `(item->>'${field->String.replaceAll("'", "''")}')`

let compositeExpr = (fields: array<string>, sep: string): string => {
  let escapedSep = sep->String.replaceAll("'", "''")
  fields->Array.map(jsonField)->Array.join(` || '${escapedSep}' || `)
}

let indexExpressions = (idx: indexConfig): (string, option<string>) => {
  let pkExpr = switch idx.pkFields {
  | Some(fields) if fields->Array.length > 0 => compositeExpr(fields, idx.pkSep->Option.getOr("/"))
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

let ensureTable = async (~pool, ~table) => {
  await pool->PgDriver.exec(
    `CREATE TABLE IF NOT EXISTS ${table} (partition_key text NOT NULL, sub_key text NOT NULL DEFAULT '', item jsonb NOT NULL, expires_at double precision, PRIMARY KEY (partition_key, sub_key))`,
  )
}

let ensureIndexes = async (~pool, ~table, ~indexes: array<indexConfig>) => {
  for i in 0 to indexes->Array.length - 1 {
    let idx = indexes->Array.getUnsafe(i)
    let (pkExpr, skExprOpt) = indexExpressions(idx)
    let indexName = `idx_${table}_${sanitizeIdent(idx.index)}`
    let cols = switch skExprOpt {
    | Some(skExpr) => `${pkExpr}, ${skExpr}`
    | None => pkExpr
    }
    await pool->PgDriver.exec(`CREATE INDEX IF NOT EXISTS ${indexName} ON ${table} (${cols})`)
  }
}

let decodeItem = (row: dict<JSON.t>): JSON.t =>
  row->Dict.get("item")->Option.getOr(JSON.Encode.null)

let computeSubKey = (item: JSON.t, subIdField: option<string>): string =>
  switch subIdField {
  | None => ""
  | Some(field) =>
    switch item->JSON.Decode.object->Option.flatMap(o => o->Dict.get(field)) {
    | Some(JSON.String(s)) => s
    | _ => ""
    }
  }

let withId = (item: JSON.t, partitionKey: string): JSON.t =>
  switch item->JSON.Decode.object {
  | Some(obj) if obj->Dict.get("id")->Option.isNone =>
    let copy = Dict.copy(obj)
    copy->Dict.set("id", JSON.Encode.string(partitionKey))
    JSON.Encode.object(copy)
  | _ => item
  }

let makeStorage = (
  ~pool: PgDriver.pool,
  ~name: string,
  ~indexes: array<indexConfig>,
  ~subIdField: option<string>,
): QueryDb_Adapter.storage => {
  let table = tableName(name)
  // Schema setup is async but makeStorage is synchronous; gate every operation on
  // this promise so the first access waits for table + index creation exactly
  // once (subsequent awaits resolve immediately).
  let ready = {
    open Promise
    ensureTable(~pool, ~table)->then(() => ensureIndexes(~pool, ~table, ~indexes))
  }

  let rowsFor = async (id: string): array<JSON.t> => {
    await ready
    (await pool->PgDriver.query(
      `SELECT item FROM ${table} WHERE partition_key = $1 AND ${notExpiredClause} ORDER BY sub_key ASC`,
      [JSON.Encode.string(id)],
    ))->Array.map(decodeItem)
  }

  let saveOne = async (id: string, state: JSON.t, ttl: option<int>) => {
    await ready
    let subKey = computeSubKey(state, subIdField)
    let expiresAt = switch ttl {
    | Some(t) => JSON.Encode.int(t)
    | None => JSON.Encode.null
    }
    let _ = await pool->PgDriver.query(
      `INSERT INTO ${table}(partition_key, sub_key, item, expires_at)
       VALUES ($1, $2, $3::jsonb, $4)
       ON CONFLICT (partition_key, sub_key)
       DO UPDATE SET item = EXCLUDED.item, expires_at = EXCLUDED.expires_at`,
      [
        JSON.Encode.string(id),
        JSON.Encode.string(subKey),
        JSON.Encode.string(JSON.stringify(state)),
        expiresAt,
      ],
    )
  }

  let load: QueryDb.load<string, JSON.t> = async id => Ok(await rowsFor(id))

  let loadStream: QueryDb.loadStream<string, JSON.t> =
    id =>
      Effect.promise(() => rowsFor(id))
      ->Stream.fromEffect
      ->Stream.flatMap(arr => Stream.fromIterable(arr))

  let save: QueryDb.save<string, JSON.t> = async (id, state, _saveMode, ttl) => {
    await saveOne(id, state, ttl)
    Ok()
  }

  let saveBatch: QueryDb.saveBatch<string, JSON.t> = async batch => {
    // pg has no synchronous multi-statement transaction helper here; the upserts
    // are independent (distinct keys) so a sequential apply is equivalent.
    for i in 0 to batch->Array.length - 1 {
      let (id, state, ttl) = batch->Array.getUnsafe(i)
      await saveOne(id, state, ttl)
    }
    Ok()
  }

  // Mirror DynamoDB's `ADD #field :inc`: read the counter on the partition item
  // (counters are single-state, sub_key=""), add inc, upsert, return NEW total.
  let count: QueryDb.count<string> = async (id, fieldName, inc) => {
    await ready
    let existing = (await rowsFor(id))->Array.get(0)->Option.flatMap(JSON.Decode.object)
    let current =
      existing
      ->Option.flatMap(o => o->Dict.get(fieldName))
      ->Option.flatMap(JSON.Decode.float)
      ->Option.mapOr(0, Float.toInt)
    let next = current + inc
    let obj = switch existing {
    | Some(o) => Dict.copy(o)
    | None => Dict.make()
    }
    obj->Dict.set("id", JSON.Encode.string(id))
    obj->Dict.set(fieldName, JSON.Encode.int(next))
    await saveOne(id, JSON.Encode.object(obj), None)
    Ok(next)
  }

  let delete: QueryDb.delete<string> = async (id, subIdOpt) => {
    await ready
    let _ = switch subIdOpt {
    | None =>
      await pool->PgDriver.query(
        `DELETE FROM ${table} WHERE partition_key = $1`,
        [JSON.Encode.string(id)],
      )
    | Some((_, subValue)) =>
      await pool->PgDriver.query(
        `DELETE FROM ${table} WHERE partition_key = $1 AND sub_key = $2`,
        [JSON.Encode.string(id), JSON.Encode.string(subValue)],
      )
    }
    Ok()
  }

  let deleteBatch: QueryDb.deleteBatch<string> = async ids => {
    for i in 0 to ids->Array.length - 1 {
      let (id, subIdOpt) = ids->Array.getUnsafe(i)
      let _ = await delete(id, subIdOpt)
    }
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

  {
    QueryDb_Adapter.resources: [],
    dataSourceName: ""->Pulumi.Output.make,
    operations: Pulumi.Output.make(ops),
  }
}

// Standalone/deploy storage: inject the pool via a provider module.
module Make = (P: {let pool: PgDriver.pool}) => {
  type api = unit
  type role = unit

  let make: QueryDb_Adapter.storageMaker<unit, unit> = (
    ~name,
    ~indexes,
    ~subIdField=?,
    ~ttl as _=?,
    ~api as _,
    ~apiRole as _,
    ~opts as _,
  ) => makeStorage(~pool=P.pool, ~name, ~indexes, ~subIdField)
}
