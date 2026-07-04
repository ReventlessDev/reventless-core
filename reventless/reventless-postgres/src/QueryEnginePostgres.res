// Postgres QueryEngine — compiles the QueryEngine query/scan AST to SQL over the
// `qdb_<name>` JSONB tables (QueryDbStorage_Postgres). The reventless-local
// LocalQueryEngine reads from in-process bus registries and ignores filters; this
// one pushes filters down to SQL, the way a production engine must.

open ReventlessCore
open Reventless

let valueToText = (v: QueryEngine.value): string =>
  switch v {
  | QueryEngine.String(s) => s
  | QueryEngine.Int(i) => i->Int.toString
  | QueryEngine.Bool(b) => b ? "true" : "false"
  }

let isNumeric = (v: QueryEngine.value): bool =>
  switch v {
  | QueryEngine.Int(_) => true
  | _ => false
  }

type paramBuilder = {mutable params: array<JSON.t>}
let param = (b: paramBuilder, v: JSON.t): string => {
  b.params->Array.push(v)
  "$" ++ Int.toString(b.params->Array.length)
}

let col = (field: string): string => `(item->>'${field->String.replaceAll("'", "''")}')`

// One Filter.config → SQL predicate, appending any bound params.
let filterSql = (b: paramBuilder, field: string, cmp: QueryEngine.Filter.comparator, v: QueryEngine.value): string => {
  let c = col(field)
  let bind = () => b->param(JSON.Encode.string(valueToText(v)))
  let cmpSql = op =>
    isNumeric(v) ? `${c}::numeric ${op} ${bind()}::numeric` : `${c} ${op} ${bind()}`
  switch cmp {
  | QueryEngine.Filter.Equal => cmpSql("=")
  | Unequal => cmpSql("<>")
  | LessOrEqual => cmpSql("<=")
  | Less => cmpSql("<")
  | GreaterOrEqual => cmpSql(">=")
  | Greater => cmpSql(">")
  | Exists => `(item ? '${field->String.replaceAll("'", "''")}')`
  | NotExists => `NOT (item ? '${field->String.replaceAll("'", "''")}')`
  | Contains => `strpos(${c}, ${bind()}) > 0`
  | NotContains => `(${c} IS NULL OR strpos(${c}, ${bind()}) = 0)`
  | BeginsWith => `starts_with(${c}, ${bind()})`
  }
}

let subIdSql = (b: paramBuilder, field: string, cmp: QueryEngine.SubId.comparator, v: QueryEngine.value): string => {
  let c = col(field)
  let bind = () => b->param(JSON.Encode.string(valueToText(v)))
  let cmpSql = op => isNumeric(v) ? `${c}::numeric ${op} ${bind()}::numeric` : `${c} ${op} ${bind()}`
  switch cmp {
  | QueryEngine.SubId.Equal => cmpSql("=")
  | Unequal => cmpSql("<>")
  | LessOrEqual => cmpSql("<=")
  | Less => cmpSql("<")
  | GreaterOrEqual => cmpSql(">=")
  | Greater => cmpSql(">")
  | BeginsWith => `starts_with(${c}, ${bind()})`
  }
}

let notExpired = QueryDbStorage_Postgres.notExpiredClause

// Add `id` (from partition_key) when absent — matches allRows/scan in the SQLite
// engine; partition-key queries return items as stored.
let decodeRow = (~withId, row: dict<JSON.t>): JSON.t => {
  let item = QueryDbStorage_Postgres.decodeItem(row)
  if withId {
    let pk = switch row->Dict.get("partition_key") {
    | Some(JSON.String(s)) => s
    | _ => ""
    }
    QueryDbStorage_Postgres.withId(item, pk)
  } else {
    item
  }
}

module Make = (P: {let pool: PgDriver.pool}) => {
  let query = async (
    ~readModelName,
    ~key=?,
    ~id: QueryEngine.value,
    ~subIdConfig=?,
    ~filterConfigs=?,
    ~ascending=?,
    ~limit=?,
  ): array<JSON.t> => {
    let table = QueryDbStorage_Postgres.tableName(readModelName)
    let keyStr = switch key {
    | Some(k) => k
    | None => valueToText(id)
    }
    let b = {params: []}
    let where = [`partition_key = ${b->param(JSON.Encode.string(keyStr))}`, notExpired]
    switch subIdConfig {
    | Some((field, cmp, v)) => where->Array.push(subIdSql(b, field, cmp, v))
    | None => ()
    }
    filterConfigs
    ->Option.getOr([])
    ->Array.forEach(((field, cmp, v)) => where->Array.push(filterSql(b, field, cmp, v)))
    let dir = ascending->Option.getOr(true) ? "ASC" : "DESC"
    let limitClause = switch limit {
    | Some(n) => ` LIMIT ${b->param(JSON.Encode.int(n))}`
    | None => ""
    }
    let sql = `SELECT partition_key, item FROM ${table} WHERE ${where->Array.join(" AND ")} ORDER BY sub_key ${dir}${limitClause}`
    (await P.pool->PgDriver.query(sql, b.params))->Array.map(decodeRow(~withId=false, ...))
  }

  let scan = async (~readModelName, ~filterConfigs, ~limit): array<JSON.t> => {
    let table = QueryDbStorage_Postgres.tableName(readModelName)
    let b = {params: []}
    let where = [notExpired]
    filterConfigs->Array.forEach(((field, cmp, v)) => where->Array.push(filterSql(b, field, cmp, v)))
    let sql = `SELECT partition_key, item FROM ${table} WHERE ${where->Array.join(" AND ")} ORDER BY partition_key, sub_key LIMIT ${b->param(JSON.Encode.int(limit))}`
    (await P.pool->PgDriver.query(sql, b.params))->Array.map(decodeRow(~withId=true, ...))
  }

  let make: QueryDb_Adapter.queryEngineMaker = _allQueryDbs =>
    Pulumi.Output.make({QueryEngine.scan, query})
}
