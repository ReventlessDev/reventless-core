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

  // ---------------------------------------------------------------------------
  // GraphQL resolver push-downs (B3.2). The Postgres resolver Lambda dispatches
  // these; they parallel the SQLite backend's `lookupByField` / `listPage` (the
  // ones registered on LocalBus). All return `id`-carrying items (COALESCE from
  // partition_key), matching the shape `QueryDbListQuery.run` operates over so
  // the connection helpers agree.
  //
  // Text comparisons use `COLLATE "C"` (byte order — memcmp), the Postgres
  // analogue of SQLite's BINARY collation, so cursor/order comparisons match
  // JS string `<` for the ASCII id/status/name fields used as sort/filter keys.
  // ---------------------------------------------------------------------------

  // Equality lookup on an indexed JSON field — rides the expression index
  // (`ensureIndexes`) instead of scanning. String comparison mirrors the
  // resolver's JS path (which only matched string-typed fields).
  let indexLookup = async (~readModelName, field: string, value: string): array<JSON.t> => {
    let table = QueryDbStorage_Postgres.tableName(readModelName)
    let b = {params: []}
    let sql = `SELECT partition_key, item FROM ${table} WHERE ${col(field)} = ${b->param(
        JSON.Encode.string(value),
      )} AND ${notExpired}`
    (await P.pool->PgDriver.query(sql, b.params))->Array.map(decodeRow(~withId=true, ...))
  }

  // Batched-by-ids lookup: BatchGetItem analogue over the projection's own
  // table. Single-key projections only (partition_key = the id). Missing ids
  // drop out of the response (no cardinality preservation), matching
  // BatchGetItem semantics.
  let byIds = async (~readModelName, ids: array<string>): array<JSON.t> => {
    if ids->Array.length == 0 {
      []
    } else {
      let table = QueryDbStorage_Postgres.tableName(readModelName)
      let b = {params: []}
      let idsJson = JSON.Encode.array(ids->Array.map(JSON.Encode.string))
      let sql = `SELECT partition_key, item FROM ${table} WHERE partition_key = ANY(${b->param(
          idsJson,
        )}::text[]) AND ${notExpired}`
      (await P.pool->PgDriver.query(sql, b.params))->Array.map(decodeRow(~withId=true, ...))
    }
  }

  // COALESCE(item->>'id', partition_key) — the effective id, byte-ordered.
  let idExprC = `COALESCE(item->>'id', partition_key) COLLATE "C"`
  let jsonTextC = (field: string): string => `${col(field)} COLLATE "C"`

  // Connection-list push-down. Builds `item->>'field'` predicates + keyset
  // WHERE + `ORDER BY … LIMIT pageSize+1` so a page reads only what it returns
  // rather than the whole read model. Reproduces `QueryDbListQuery` semantics
  // exactly for the shapes it handles; returns `None` (→ the resolver Lambda
  // falls back to `scan` + the shared spec) for shapes not bit-exact in SQL:
  // case-insensitive search/searchPrefix, Relay-global-id `ids`, and backward
  // pagination (last/before). Cursor values, edges, and pageInfo are built by
  // the SAME `QueryDbListQuery` helpers the fallback uses, so only the
  // WHERE/ORDER/LIMIT needs to match — the parity harness asserts it does
  // (SQLite ≡ Postgres ≡ spec). Mirrors QueryDbStorage_Sqlite.listPage.
  let listPage = async (
    ~readModelName,
    ~argsDict: dict<JSON.t>,
    ~capability: GraphQL_FragmentGenerator.serverCapability,
    ~labelField as _,
  ): option<JSON.t> => {
    let table = QueryDbStorage_Postgres.tableName(readModelName)
    let filterDict =
      argsDict->Dict.get("filter")->Option.flatMap(JSON.Decode.object)->Option.getOr(Dict.make())
    let strNonEmpty = k =>
      filterDict
      ->Dict.get(k)
      ->Option.flatMap(JSON.Decode.string)
      ->Option.mapOr(false, s => s->String.length > 0)
    let hasIds =
      filterDict
      ->Dict.get("ids")
      ->Option.flatMap(JSON.Decode.array)
      ->Option.mapOr(false, a => a->Array.length > 0)
    let last = argsDict->Dict.get("last")->Option.flatMap(JSON.Decode.float)
    let before = argsDict->Dict.get("before")->Option.flatMap(JSON.Decode.string)
    if (
      strNonEmpty("search") ||
      strNonEmpty("searchPrefix") ||
      hasIds ||
      last->Option.isSome ||
      before->Option.isSome
    ) {
      None
    } else {
      let b = {params: []}
      let whereParts = [notExpired]
      let valString = v =>
        switch v->JSON.Decode.string {
        | Some(s) => Some(s)
        | None => v->JSON.Decode.float->Option.map(f => Float.toString(f))
        }
      capability.filterFields->Array.forEach(f => {
        switch filterDict->Dict.get(f.name ++ "Eq") {
        | Some(v) when v != JSON.Encode.null =>
          whereParts->Array.push(
            `${jsonTextC(f.name)} = ${b->param(JSON.Encode.string(valString(v)->Option.getOr("")))}`,
          )
        | _ => ()
        }
        if f.range {
          switch filterDict->Dict.get(f.name ++ "From") {
          | Some(v) when v != JSON.Encode.null =>
            whereParts->Array.push(
              `${jsonTextC(f.name)} >= ${b->param(
                  JSON.Encode.string(valString(v)->Option.getOr("")),
                )}`,
            )
          | _ => ()
          }
          switch filterDict->Dict.get(f.name ++ "To") {
          | Some(v) when v != JSON.Encode.null =>
            whereParts->Array.push(
              `${jsonTextC(f.name)} <= ${b->param(
                  JSON.Encode.string(valString(v)->Option.getOr("")),
                )}`,
            )
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
      | Some(f) => jsonTextC(f)
      | None => idExprC
      }
      switch argsDict->Dict.get("after")->Option.flatMap(JSON.Decode.string) {
      | Some(c) =>
        whereParts->Array.push(
          `${cursorExpr} ${isDesc ? "<" : ">"} ${b->param(
              JSON.Encode.string(ReventlessCore.QueryDbListQuery.decodeCursor(c)),
            )}`,
        )
      | None => ()
      }
      let orderClause = switch orderByField {
      | Some(f) => `${jsonTextC(f)} ${isDesc ? "DESC" : "ASC"}, ${idExprC} ASC`
      | None => `${idExprC} ASC`
      }
      let pageSize =
        argsDict
        ->Dict.get("first")
        ->Option.flatMap(JSON.Decode.float)
        ->Option.map(Float.toInt)
        ->Option.getOr(ReventlessCore.QueryDbListQuery.defaultListPageSize)
      let sql = `SELECT partition_key, item FROM ${table} WHERE ${whereParts->Array.join(
          " AND ",
        )} ORDER BY ${orderClause} LIMIT ${b->param(JSON.Encode.int(pageSize + 1))}`
      let rows = (await P.pool->PgDriver.query(sql, b.params))->Array.map(decodeRow(~withId=true, ...))
      let hasMore = rows->Array.length > pageSize
      let pageItems = rows->Array.slice(~start=0, ~end=pageSize)
      let cursorField = orderByField->Option.getOr("id")
      let cursorValueOf = item =>
        ReventlessCore.QueryDbListQuery.getFieldString(item, cursorField)->Option.getOr(
          ReventlessCore.QueryDbListQuery.getId(item),
        )
      Some(
        ReventlessCore.QueryDbListQuery.buildConnection(
          ~pageItems,
          ~hasNextPage=hasMore,
          ~hasPreviousPage=false,
          ~cursorValueOf,
        ),
      )
    }
  }

  // Sub-id connection push-down: the `{single}Items(id, filter, first/after/
  // last/before)` query. Keyset over `sub_key` WITHIN one partition — a page
  // reads only what it returns. Reproduces QueryDbResolvers_GraphQL's items
  // resolver (SortKey_Filter + forward/backward keyset), entirely in SQL since
  // sub_key IS the sort key. Cursor = base64 of the sub_key value; comparisons
  // use COLLATE "C" (byte order) to match JS string `<`. Unlike the main list
  // there is no declined-shape fallback — every items shape maps to SQL.
  let itemsPage = async (
    ~readModelName,
    ~subIdField as _: string,
    ~id: string,
    ~argsDict: dict<JSON.t>,
  ): JSON.t => {
    let table = QueryDbStorage_Postgres.tableName(readModelName)
    let filterDict =
      argsDict->Dict.get("filter")->Option.flatMap(JSON.Decode.object)->Option.getOr(Dict.make())
    let fstr = k => filterDict->Dict.get(k)->Option.flatMap(JSON.Decode.string)
    let orderDesc = fstr("order")->Option.mapOr(false, o => o == "DESC")
    let last = argsDict->Dict.get("last")->Option.flatMap(JSON.Decode.float)->Option.map(Float.toInt)
    let first = argsDict->Dict.get("first")->Option.flatMap(JSON.Decode.float)->Option.map(Float.toInt)
    let after = argsDict->Dict.get("after")->Option.flatMap(JSON.Decode.string)
    let before = argsDict->Dict.get("before")->Option.flatMap(JSON.Decode.string)
    let isBackward = last->Option.isSome

    let sk = `sub_key COLLATE "C"`
    let b = {params: []}
    let where = [`partition_key = ${b->param(JSON.Encode.string(id))}`, notExpired]
    fstr("prefix")->Option.forEach(p =>
      where->Array.push(`starts_with(sub_key, ${b->param(JSON.Encode.string(p))})`)
    )
    fstr("from")->Option.forEach(f => where->Array.push(`${sk} >= ${b->param(JSON.Encode.string(f))}`))
    fstr("to")->Option.forEach(t => where->Array.push(`${sk} <= ${b->param(JSON.Encode.string(t))}`))
    fstr("eq")->Option.forEach(e => where->Array.push(`${sk} = ${b->param(JSON.Encode.string(e))}`))
    // Keyset: forward excludes ≤ after; backward excludes ≥ before.
    switch (isBackward, after, before) {
    | (false, Some(c), _) =>
      where->Array.push(`${sk} > ${b->param(JSON.Encode.string(ReventlessCore.QueryDbListQuery.decodeCursor(c)))}`)
    | (true, _, Some(c)) =>
      where->Array.push(`${sk} < ${b->param(JSON.Encode.string(ReventlessCore.QueryDbListQuery.decodeCursor(c)))}`)
    | _ => ()
    }
    // Page-fetch direction is the LOGICAL order forward, and its OPPOSITE
    // backward (take the N nearest `before`, then reverse to logical) — mirrors
    // the resolver's `reverse = isBackward ? !orderDesc : orderDesc`.
    let fetchDesc = isBackward ? !orderDesc : orderDesc
    let pageSize = (isBackward ? last : first)->Option.getOr(ReventlessCore.QueryDbListQuery.defaultListPageSize)
    let sql = `SELECT partition_key, sub_key, item FROM ${table} WHERE ${where->Array.join(
        " AND ",
      )} ORDER BY ${sk} ${fetchDesc ? "DESC" : "ASC"} LIMIT ${b->param(JSON.Encode.int(pageSize + 1))}`
    let rows = await P.pool->PgDriver.query(sql, b.params)
    let hasMore = rows->Array.length > pageSize
    let taken = rows->Array.slice(~start=0, ~end=pageSize)
    // Backward fetched in reverse-logical order → flip back to logical.
    let logical = isBackward ? taken->Array.toReversed : taken
    let pageItems = logical->Array.map(decodeRow(~withId=false, ...))
    // Cursor = the row's sub_key (== the item's subIdField value).
    let subKeyOf = (row: dict<JSON.t>) =>
      switch row->Dict.get("sub_key") {
      | Some(JSON.String(s)) => s
      | _ => ""
      }
    let cursors = logical->Array.map(subKeyOf)
    let edges =
      pageItems->Array.mapWithIndex((item, i) =>
        Obj.magic({
          "node": item,
          "cursor": ReventlessCore.QueryDbListQuery.encodeCursor(cursors->Array.getUnsafe(i)),
        })
      )
    let startCursor =
      cursors->Array.get(0)->Option.map(ReventlessCore.QueryDbListQuery.encodeCursor)
    let endCursor =
      cursors->Array.get(cursors->Array.length - 1)->Option.map(ReventlessCore.QueryDbListQuery.encodeCursor)
    Obj.magic({
      "edges": edges,
      "pageInfo": {
        "hasNextPage": !isBackward && hasMore,
        "hasPreviousPage": isBackward && hasMore,
        "startCursor": startCursor->Nullable.fromOption,
        "endCursor": endCursor->Nullable.fromOption,
      },
    })
  }

  let make: QueryDb_Adapter.queryEngineMaker = _allQueryDbs =>
    Pulumi.Output.make({QueryEngine.scan, query})
}
