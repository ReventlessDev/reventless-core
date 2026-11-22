// The local backfill of a view's derived trail dates: a row saved before them
// gets them, a current row and a row without a trail are left alone, and a
// second run finds nothing to change.

open JestGlobals

module Rederive = LocalViewsRederive

let trail = `[{"state":"Placed","at":"2026-03-02T09:00:00Z"},{"state":"Shipped","at":"2026-03-02T10:00:00Z"}]`

let openStore = () => {
  let dir = NodeFs.mkdtempSync(NodePath.join([NodeOs.tmpdir(), "reventless-rederive-"]))
  let db = SqliteDriver.openDb(~path=NodePath.join([dir, "local.db"]))
  db->SqliteDriver.exec(
    "CREATE TABLE qdb_Orders (partition_key TEXT NOT NULL, sub_key TEXT NOT NULL DEFAULT '', item TEXT NOT NULL, expires_at INTEGER, PRIMARY KEY (partition_key, sub_key))",
  )
  let insert =
    db->SqliteDriver.prepare("INSERT INTO qdb_Orders(partition_key, sub_key, item) VALUES(?,'',?)")
  let current =
    `{"id":"o2","trail":${trail}}`->JSON.parseOrThrow->JSON.Decode.object->Option.getOrThrow
  current->Reventless.Lifecycle.Trail.writeDerived(~field="trail")
  [
    ("o1", `{"id":"o1","trail":${trail}}`),
    ("o2", current->JSON.Encode.object->JSON.stringify),
    ("o3", `{"id":"o3","lifecycle":"Placed"}`),
  ]->Array.forEach(((id, item)) =>
    insert->SqliteDriver.run([JSON.Encode.string(id), JSON.Encode.string(item)])
  )
  db
}

let item = (db, id) =>
  db
  ->SqliteDriver.prepare("SELECT item FROM qdb_Orders WHERE partition_key = ?")
  ->SqliteDriver.get([JSON.Encode.string(id)])
  ->Option.flatMap(r => r->Dict.get("item"))
  ->Option.flatMap(JSON.Decode.string)
  ->Option.getOrThrow
  ->JSON.parseOrThrow
  ->JSON.Decode.object
  ->Option.getOrThrow

describe("LocalViewsRederive", () => {
  testSync("a dry run counts the rows to change and writes nothing", () => {
    let db = openStore()
    let tallies = db->Rederive.rederiveDb(~apply=false)
    expect(
      tallies->Array.map(t => (t.table, t.rows, t.withTrail, t.toChange, t.updated)),
    )->toEqual([("qdb_Orders", 3, 2, 1, 0)])
    expect(item(db, "o1")->Dict.get("_entered_current"))->toEqual(None)
  })

  testSync("applying writes the dates, and a second run finds nothing", () => {
    let db = openStore()
    let first = db->Rederive.rederiveDb(~apply=true)
    expect(first->Array.map(t => (t.toChange, t.updated, t.skipped)))->toEqual([(1, 1, 0)])
    let o1 = item(db, "o1")
    expect(o1->Dict.get("_entered_current"))->toEqual(
      Some(JSON.Encode.string("2026-03-02T10:00:00Z")),
    )
    expect(o1->Dict.get("_visits_Placed"))->toEqual(Some(JSON.Encode.int(1)))
    expect(item(db, "o3")->Dict.keysToArray)->toEqual(["id", "lifecycle"])
    let second = db->Rederive.rederiveDb(~apply=true)
    expect(second->Array.map(t => (t.toChange, t.updated)))->toEqual([(0, 0)])
  })
})
