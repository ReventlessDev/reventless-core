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
  registerQueryDbListPage: (
    string,
    (
      ~argsDict: dict<JSON.t>,
      ~capability: GraphQL_FragmentGenerator.serverCapability,
      ~labelField: string,
      ~ownerScope: (string, string)=?,
      ~retiredScope: Reventless.OwnerScope.retiredScope=?,
    ) => option<JSON.t>,
  ) => unit,
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
  // First-insert detection. DynamoDB streams hand the AWS StateTopic Lambda an
  // eventName that separates INSERT from MODIFY; an upsert reports neither, so
  // ask the table before writing. Carries `notExpiredClause` because that is what
  // a reader sees: a row aged past its TTL is invisible to them, so overwriting
  // it is an insert — the same descriptor pair (Removed, then Added) DynamoDB
  // emits when a TTL delete is followed by a fresh Put.
  let existsStmt = db->SqliteDriver.prepare(
    `SELECT 1 FROM ${table} WHERE partition_key = ? AND sub_key = ? AND ${notExpiredClause} LIMIT 1`,
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

  let publishSaved = (~changeKind: string, id: string, state: JSON.t) => {
    let subKey = computeSubKey(state, subIdField)
    let descriptor = LocalStateChangeDescriptor.make(
      ~changeKind,
      ~id=entityKeyFor(id, subKey),
      ~state=Some(state),
      ~seq=LocalStateChangeDescriptor.nextSequence(),
      ~retiredField=?LocalStateChangeDescriptor.retiredSpecFor(name)->Option.map(r => r.field),
      ~retiredValue=?LocalStateChangeDescriptor.retiredSpecFor(name)->Option.flatMap(r => r.value),
    )
    bus.publishStateChange(~name, ~descriptor)
  }

  // Must be called BEFORE the write — afterwards every row exists.
  let saveKind = (id: string, state: JSON.t): string => {
    let present =
      existsStmt
      ->SqliteDriver.get([
        JSON.Encode.string(id),
        JSON.Encode.string(computeSubKey(state, subIdField)),
      ])
      ->Option.isSome
    present ? "Updated" : "Added"
  }

  let publishRemoved = (id: string, subKey: string) => {
    let descriptor = LocalStateChangeDescriptor.make(
      ~changeKind="Removed",
      ~id=entityKeyFor(id, subKey),
      ~state=None,
      ~seq=LocalStateChangeDescriptor.nextSequence(),
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
    let changeKind = saveKind(id, state)
    saveOne(id, state, ttl)
    publishSaved(~changeKind, id, state)
    Ok()
  }

  let saveBatch: QueryDb.saveBatch<string, JSON.t> = async batch => {
    // Kinds are decided inside the transaction, each immediately before its own
    // write, so a batch that touches one key twice reports Added then Updated.
    let kinds = []
    db->SqliteDriver.transaction(() =>
      batch->Array.forEach(((id, state, ttl)) => {
        kinds->Array.push(saveKind(id, state))
        saveOne(id, state, ttl)
      })
    )
    batch->Array.forEachWithIndex(((id, state, _), i) =>
      publishSaved(~changeKind=kinds->Array.get(i)->Option.getOr("Updated"), id, state)
    )
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
    // `existing` already answered the first-insert question — a counter's very
    // first increment creates its row, and that is an Added like any other.
    let changeKind = existing->Option.isSome ? "Updated" : "Added"
    saveOne(id, newItem, None)
    publishSaved(~changeKind, id, newItem)
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

  // Connection-list push-down. Builds `json_extract` predicates + `ORDER BY …
  // LIMIT pageSize+1` so a page fetch reads only what it returns rather than the
  // whole read model. Reproduces `QueryDbListQuery` semantics exactly for the
  // shapes it handles; returns None (→ the resolver falls back to that shared
  // spec over a full scan) for shapes not bit-exact in SQL: case-insensitive
  // search/searchPrefix, Relay-global-id `ids`, and backward pagination
  // (last/before). Cursor values, edges, and pageInfo are built by the SAME
  // `QueryDbListQuery` helpers the fallback uses, so only the WHERE/ORDER/LIMIT
  // needs to match — which the parity harness asserts across a data + args
  // matrix. Comparisons use TEXT (CAST) to mirror the JS string-comparison
  // semantics; BINARY collation agrees with JS `<` for the ASCII id/status/name
  // fields used as sort/filter keys.
  let listStmtCache: Dict.t<SqliteDriver.statement> = Dict.make()
  let preparedList = (sql: string): SqliteDriver.statement =>
    switch listStmtCache->Dict.get(sql) {
    | Some(s) => s
    | None =>
      let s = db->SqliteDriver.prepare(sql)
      listStmtCache->Dict.set(sql, s)
      s
    }
  let jsonText = (field: string): string =>
    `CAST(json_extract(item, '$.${field->String.replaceAll("'", "''")}') AS TEXT)`
  let idExpr = "COALESCE(json_extract(item, '$.id'), partition_key)"
  let listPage = (
    ~argsDict: dict<JSON.t>,
    ~capability: GraphQL_FragmentGenerator.serverCapability,
    ~labelField as _,
    ~ownerScope: option<(string, string)>=?,
    ~retiredScope: option<Reventless.OwnerScope.retiredScope>=?,
  ): option<JSON.t> => {
    let filterDict =
      argsDict->Dict.get("filter")->Option.flatMap(JSON.Decode.object)->Option.getOr(Dict.make())
    let strNonEmpty = k =>
      filterDict->Dict.get(k)->Option.flatMap(JSON.Decode.string)->Option.mapOr(false, s => s->String.length > 0)
    let hasIds =
      filterDict->Dict.get("ids")->Option.flatMap(JSON.Decode.array)->Option.mapOr(false, a => a->Array.length > 0)
    let last = argsDict->Dict.get("last")->Option.flatMap(JSON.Decode.float)
    let before = argsDict->Dict.get("before")->Option.flatMap(JSON.Decode.string)
    if strNonEmpty("search") || strNonEmpty("searchPrefix") || hasIds || last->Option.isSome || before->Option.isSome {
      None
    } else {
      let whereParts = [notExpiredClause]
      let params = []
      // Pushed into the SQL rather than applied to the returned page, because the
      // LIMIT below is what makes a page: narrowing afterwards would return fewer
      // rows than asked for while still reporting a next page.
      switch ownerScope {
      | Some((field, required)) =>
        whereParts->Array.push(`${jsonText(field)} = ?`)
        params->Array.push(JSON.Encode.string(required))
      | None => ()
      }
      // `IS NOT 1`, not `= 0`, and on the raw extraction rather than through
      // `jsonText`. SQLite renders a JSON true as the integer 1 and a missing
      // path as NULL, and `IS NOT` is the comparison that treats NULL as a value
      // rather than poisoning the predicate. Three cases have to land the way the
      // in-memory spec lands them: absent keeps the row (a row written before the
      // annotation is not retired), false keeps it, and a value that is not a
      // JSON boolean keeps it too — which `= 0` would get wrong, since a string
      // `'true'` compares unequal to 0 and the row would vanish on this backend
      // only. `QueryDbListPushdownParityTest` is what holds the two together.
      //
      // The state form compares against the state's text instead of 1, and the
      // three cases land identically: absent is NULL, a different state compares
      // unequal, and a non-string value is not the state either.
      switch retiredScope {
      | Some(scope) =>
        let path = `json_extract(item, '$.${scope.field->String.replaceAll("'", "''")}')`
        whereParts->Array.push(
          switch scope.value {
          | None => `${path} IS NOT 1`
          | Some(state) => `${path} IS NOT '${state->String.replaceAll("'", "''")}'`
          },
        )
      | None => ()
      }
      let valString = v =>
        switch v->JSON.Decode.string {
        | Some(s) => Some(s)
        | None => v->JSON.Decode.float->Option.map(f => Float.toString(f))
        }
      capability.filterFields->Array.forEach(f => {
        switch filterDict->Dict.get(f.name ++ "Eq") {
        | Some(v) when v != JSON.Encode.null =>
          whereParts->Array.push(`${jsonText(f.name)} = ?`)
          params->Array.push(JSON.Encode.string(valString(v)->Option.getOr("")))
        | _ => ()
        }
        if f.range {
          switch filterDict->Dict.get(f.name ++ "From") {
          | Some(v) when v != JSON.Encode.null =>
            whereParts->Array.push(`${jsonText(f.name)} >= ?`)
            params->Array.push(JSON.Encode.string(valString(v)->Option.getOr("")))
          | _ => ()
          }
          switch filterDict->Dict.get(f.name ++ "To") {
          | Some(v) when v != JSON.Encode.null =>
            whereParts->Array.push(`${jsonText(f.name)} <= ?`)
            params->Array.push(JSON.Encode.string(valString(v)->Option.getOr("")))
          | _ => ()
          }
        }
      })
      let orderByDict = argsDict->Dict.get("orderBy")->Option.flatMap(JSON.Decode.object)
      let orderByField =
        orderByDict->Option.flatMap(ob => ob->Dict.get("field"))->Option.flatMap(JSON.Decode.string)
      let isDesc =
        orderByDict
        ->Option.flatMap(ob => ob->Dict.get("direction"))
        ->Option.flatMap(JSON.Decode.string)
        ->Option.getOr("ASC") == "DESC"
      let cursorExpr = switch orderByField {
      | Some(f) => jsonText(f)
      | None => idExpr
      }
      switch argsDict->Dict.get("after")->Option.flatMap(JSON.Decode.string) {
      | Some(c) =>
        whereParts->Array.push(`${cursorExpr} ${isDesc ? "<" : ">"} ?`)
        params->Array.push(JSON.Encode.string(QueryDbListQuery.decodeCursor(c)))
      | None => ()
      }
      let orderClause = switch orderByField {
      | Some(f) => `${jsonText(f)} ${isDesc ? "DESC" : "ASC"}, ${idExpr} ASC`
      | None => `${idExpr} ASC`
      }
      let pageSize =
        argsDict
        ->Dict.get("first")
        ->Option.flatMap(JSON.Decode.float)
        ->Option.map(Float.toInt)
        ->Option.getOr(QueryDbListQuery.defaultListPageSize)
      let sql = `SELECT partition_key, item FROM ${table} WHERE ${whereParts->Array.join(" AND ")} ORDER BY ${orderClause} LIMIT ?`
      let rows =
        preparedList(sql)
        ->SqliteDriver.all(params->Array.concat([JSON.Encode.int(pageSize + 1)]))
        ->Array.map(rowToItem)
      let hasMore = rows->Array.length > pageSize
      let pageItems = rows->Array.slice(~start=0, ~end=pageSize)
      let cursorField = orderByField->Option.getOr("id")
      let cursorValueOf = item =>
        QueryDbListQuery.getFieldString(item, cursorField)->Option.getOr(QueryDbListQuery.getId(item))
      Some(
        QueryDbListQuery.buildConnection(
          ~pageItems,
          ~hasNextPage=hasMore,
          ~hasPreviousPage=false,
          ~cursorValueOf,
        ),
      )
    }
  }
  bus.registerQueryDbListPage(name, listPage)

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
    registerQueryDbListPage: Bus.registerQueryDbListPage,
  }

  let make: QueryDb_Adapter.storageMaker<unit, unit> = (
    ~name,
    ~indexes,
    ~subIdField=?,
    ~ttl as _=?,
    ~api as _,
    ~apiRole as _,
    ~owner as _, ~opts as _,
  ) => makeStorage(~db=DbProvider.db, ~bus=busCallbacks, ~name, ~indexes, ~subIdField)
}
