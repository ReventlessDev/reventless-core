// SQLite-backed task bucket.
//
// The in-memory Task_Builder treats the bucket as opaque: it only needs a
// resource to identify the bucket. There is no read/write contract on the
// bucketMaker today, so the SQLite variant just provisions a table for
// future task-replay tooling and exposes plain put/get helpers that
// callers can use directly.
//
// Schema:
//   CREATE TABLE task_object (
//     bucket TEXT NOT NULL,
//     key    TEXT NOT NULL,
//     body   BLOB NOT NULL,
//     PRIMARY KEY (bucket, key)
//   )

let ensureSchema = (db: SqliteDriver.t) =>
  db->SqliteDriver.exec(
    "CREATE TABLE IF NOT EXISTS task_object (bucket TEXT NOT NULL, key TEXT NOT NULL, body BLOB NOT NULL, PRIMARY KEY (bucket, key))",
  )

let put = (~db: SqliteDriver.t, ~bucket: string, ~key: string, ~body: string): unit => {
  ensureSchema(db)
  let stmt = db->SqliteDriver.prepare(
    "INSERT INTO task_object(bucket, key, body) VALUES(?, ?, ?) ON CONFLICT(bucket, key) DO UPDATE SET body = excluded.body",
  )
  stmt->SqliteDriver.run([
    JSON.Encode.string(bucket),
    JSON.Encode.string(key),
    JSON.Encode.string(body),
  ])
}

let get = (~db: SqliteDriver.t, ~bucket: string, ~key: string): option<string> => {
  ensureSchema(db)
  let stmt = db->SqliteDriver.prepare(
    "SELECT body FROM task_object WHERE bucket = ? AND key = ?",
  )
  switch stmt->SqliteDriver.get([JSON.Encode.string(bucket), JSON.Encode.string(key)]) {
  | Some(row) =>
    switch row->Dict.get("body") {
    | Some(JSON.String(s)) => Some(s)
    | _ => None
    }
  | None => None
  }
}
