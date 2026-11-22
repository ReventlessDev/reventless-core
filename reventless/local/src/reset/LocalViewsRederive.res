// Backfills the dates a lifecycle trail derives on the rows of a local SQLite
// store: a row saved before its view derived them carries a trail and none of
// the `_entered_*`, `_visits_*` and `_trail` attributes, so a filter or order on
// them leaves it out until its next write. A dry run is the default.

open ReventlessSeed

module Trail = Reventless.Lifecycle.Trail

type tally = {table: string, rows: int, withTrail: int, toChange: int, updated: int, skipped: int}

let viewTables = (db): array<string> =>
  db
  ->SqliteDriver.prepare(
    "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'qdb\\_%' ESCAPE '\\' ORDER BY name",
  )
  ->SqliteDriver.all([])
  ->Array.filterMap(r => r->Dict.get("name")->Option.flatMap(JSON.Decode.string))

/** One table's rows brought in line with their trails. A row is written only
    while it still holds the text it was read with; one saved since then got its
    dates from that save and is skipped. */
let rederiveTable = (db, ~table: string, ~apply: bool): tally => {
  let rows =
    db
    ->SqliteDriver.prepare(`SELECT partition_key, sub_key, item FROM ${table}`)
    ->SqliteDriver.all([])
  let update =
    db->SqliteDriver.prepare(
      `UPDATE ${table} SET item = ? WHERE partition_key = ? AND sub_key = ? AND item = ?`,
    )
  let changes = db->SqliteDriver.prepare("SELECT changes() AS n")
  rows->Array.reduce({table, rows: 0, withTrail: 0, toChange: 0, updated: 0, skipped: 0}, (
    t,
    r,
  ) => {
    let text = r->Dict.get("item")->Option.flatMap(JSON.Decode.string)->Option.getOr("{}")
    let item = text->JSON.parseOrThrow->JSON.Decode.object->Option.getOr(Dict.make())
    let t = {...t, rows: t.rows + 1}
    switch item->Trail.fieldOfRow {
    | None => t
    | Some(field) =>
      let t = {...t, withTrail: t.withTrail + 1}
      if item->Trail.rederive(~field)->Trail.isUnchanged {
        t
      } else if !apply {
        {...t, toChange: t.toChange + 1}
      } else {
        let next = item->Dict.copy
        next->Trail.writeDerived(~field)
        update->SqliteDriver.run([
          next->JSON.Encode.object->JSON.stringify->JSON.Encode.string,
          r->Dict.get("partition_key")->Option.getOr(JSON.Encode.null),
          r->Dict.get("sub_key")->Option.getOr(JSON.Encode.string("")),
          JSON.Encode.string(text),
        ])
        let written =
          changes
          ->SqliteDriver.get([])
          ->Option.flatMap(c => c->Dict.get("n"))
          ->Option.flatMap(JSON.Decode.float)
          ->Option.getOr(0.) > 0.
        written
          ? {...t, toChange: t.toChange + 1, updated: t.updated + 1}
          : {...t, toChange: t.toChange + 1, skipped: t.skipped + 1}
      }
    }
  })
}

let rederiveDb = (db, ~apply: bool): array<tally> =>
  db->viewTables->Array.map(table => rederiveTable(db, ~table, ~apply))

/** Runs the backfill on the store a running platform opened, or the one
    `REVENTLESS_LOCAL_BACKEND` names; reads only unless `--apply` is given. */
let run = (~dbPath: option<string>=?): unit => {
  let go = async () => {
    let apply = NodeProcess.argv->Array.includes("--apply")
    switch await LocalSeedReset.resolveStore(~dbPath?) {
    | Error(reason) => Console.log(`Nothing to backfill — ${reason}`)
    | Ok(path) if !NodeFs.existsSync(path) =>
      Console.log(`Nothing to backfill — no store at ${path}.`)
    | Ok(path) =>
      let db = SqliteDriver.openDb(~path)
      Console.log(`Trail dates in ${path}${apply ? "" : " (dry run; --apply writes)"}`)
      let tallies = rederiveDb(db, ~apply)
      tallies->Array.forEach(t =>
        if t.withTrail > 0 {
          Console.log(
            `  ${t.table->String.padEnd(
                36,
                " ",
              )} rows ${t.rows->Int.toString}  with a trail ${t.withTrail->Int.toString}` ++ (
              apply
                ? `  updated ${t.updated->Int.toString}  skipped ${t.skipped->Int.toString}`
                : `  to change ${t.toChange->Int.toString}`
            ),
          )
        }
      )
      db->SqliteDriver.close
    }
    Seed.Prompt.close()
  }
  go()->ignore
}
