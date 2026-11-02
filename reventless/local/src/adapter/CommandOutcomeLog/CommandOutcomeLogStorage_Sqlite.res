// The command outcomes of a SQLite platform, kept in its store across restarts.

type entry = CommandOutcomeLogEntry.t

let table = "reventless_command_outcomes"

let ensureSchema = db => {
  db->SqliteDriver.exec(
    `CREATE TABLE IF NOT EXISTS ${table} (seq INTEGER PRIMARY KEY AUTOINCREMENT, flow TEXT, msg_id TEXT NOT NULL, item TEXT NOT NULL)`,
  )
  db->SqliteDriver.exec(`CREATE INDEX IF NOT EXISTS ${table}_flow ON ${table} (flow, seq)`)
  db->SqliteDriver.exec(`CREATE INDEX IF NOT EXISTS ${table}_msg ON ${table} (msg_id)`)
}

let str = JSON.Encode.string

let append = (db, e: entry) =>
  db
  ->SqliteDriver.prepare(`INSERT INTO ${table} (flow, msg_id, item) VALUES (?, ?, ?)`)
  ->SqliteDriver.run([
    e.flow->Option.mapOr(JSON.Encode.null, str),
    str(e.msgId),
    str(e.item->JSON.stringify),
  ])

let entryOfRow = (row: dict<JSON.t>): option<entry> => {
  let s = k => row->Dict.get(k)->Option.flatMap(JSON.Decode.string)
  switch (
    row->Dict.get("seq")->Option.flatMap(JSON.Decode.float),
    s("msg_id"),
    s("item")->Option.flatMap(i =>
      try Some(JSON.parseOrThrow(i)) catch {
      | _ => None
      }
    ),
  ) {
  | (Some(seq), Some(msgId), Some(item)) =>
    Some({seq: seq->Float.toInt, flow: ?s("flow"), msgId, item})
  | _ => None
  }
}

/** Up to `first` entries matching the filter, newest first, below the `before` sequence number. */
let read = (db, ~filter: CommandOutcomeLogEntry.filter, ~before: option<int>, ~first: int): array<
  entry,
> => {
  let where = []
  let params = []
  let add = (clause, value) => {
    where->Array.push(clause)
    params->Array.push(value)
  }
  filter.correlationId->Option.forEach(c => add("flow = ?", str(c)))
  filter.msgId->Option.forEach(m => add("msg_id = ?", str(m)))
  before->Option.forEach(b => add("seq < ?", JSON.Encode.int(b)))
  let sql = `SELECT seq, flow, msg_id, item FROM ${table}${where == []
      ? ""
      : " WHERE " ++ where->Array.join(" AND ")} ORDER BY seq DESC LIMIT ?`
  params->Array.push(JSON.Encode.int(first))
  db->SqliteDriver.prepare(sql)->SqliteDriver.all(params)->Array.filterMap(entryOfRow)
}
