// The row changes of a SQLite platform, kept in its store across restarts.

type entry = ViewChangeLogEntry.t

let table = "reventless_view_changes"

let ensureSchema = db => {
  db->SqliteDriver.exec(
    `CREATE TABLE IF NOT EXISTS ${table} (seq INTEGER PRIMARY KEY AUTOINCREMENT, flow TEXT, view TEXT NOT NULL, key TEXT NOT NULL, msg_ids TEXT NOT NULL, item TEXT NOT NULL)`,
  )
  db->SqliteDriver.exec(`CREATE INDEX IF NOT EXISTS ${table}_flow ON ${table} (flow, seq)`)
  db->SqliteDriver.exec(`CREATE INDEX IF NOT EXISTS ${table}_row ON ${table} (view, key, seq)`)
}

let str = JSON.Encode.string

let append = (db, e: entry) =>
  db
  ->SqliteDriver.prepare(
    `INSERT INTO ${table} (flow, view, key, msg_ids, item) VALUES (?, ?, ?, ?, ?)`,
  )
  ->SqliteDriver.run([
    e.flow->Option.mapOr(JSON.Encode.null, str),
    str(e.view),
    str(e.key),
    str(e.msgIds->Array.join(",")),
    str(e.item->JSON.stringify),
  ])

let entryOfRow = (row: dict<JSON.t>): option<entry> => {
  let s = k => row->Dict.get(k)->Option.flatMap(JSON.Decode.string)
  switch (
    row->Dict.get("seq")->Option.flatMap(JSON.Decode.float),
    s("view"),
    s("key"),
    s("item")->Option.flatMap(i =>
      try Some(JSON.parseOrThrow(i)) catch {
      | _ => None
      }
    ),
  ) {
  | (Some(seq), Some(view), Some(key), Some(item)) =>
    Some({
      seq: seq->Float.toInt,
      flow: ?s("flow"),
      view,
      key,
      msgIds: s("msg_ids")->Option.mapOr([], m => m == "" ? [] : m->String.split(",")),
      item,
    })
  | _ => None
  }
}

/** Up to `first` entries matching the filter, newest first, below the `before` sequence number.
    The flow, view and key narrow in SQL; a message id is tested on the rows read. */
let read = (db, ~filter: ViewChangeLogEntry.filter, ~before: option<int>, ~first: int): array<
  entry,
> => {
  let where = []
  let params = []
  let add = (clause, value) => {
    where->Array.push(clause)
    params->Array.push(value)
  }
  filter.correlationId->Option.forEach(c => add("flow = ?", str(c)))
  filter.view->Option.forEach(v => add("view = ?", str(v)))
  filter.key->Option.forEach(k => add("key = ?", str(k)))
  filter.msgId->Option.forEach(m => add("(',' || msg_ids || ',') LIKE ?", str(`%,${m},%`)))
  before->Option.forEach(b => add("seq < ?", JSON.Encode.int(b)))
  let sql = `SELECT seq, flow, view, key, msg_ids, item FROM ${table}${where == []
      ? ""
      : " WHERE " ++ where->Array.join(" AND ")} ORDER BY seq DESC LIMIT ?`
  params->Array.push(JSON.Encode.int(first))
  db->SqliteDriver.prepare(sql)->SqliteDriver.all(params)->Array.filterMap(entryOfRow)
}
