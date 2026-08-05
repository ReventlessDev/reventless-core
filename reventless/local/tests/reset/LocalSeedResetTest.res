// Classification tests for the scoped local reset.
//
// The fixture is not invented: it is the table set, checkpoint names and plugin
// structures captured from a live hybrid store on 2026-08-05 — including the four
// components (`qdb_ImportProductAudit` and the three `*Todo` tables) that appear in
// NO plugin structure, and `qdb_UiFragments`, which the platform's own structure
// omits. Those omissions are the reason classification is discovery-first rather
// than structure-driven, so a fixture without them would test the easy case only.
//
// This is the pinning test the module's header refers to: if core gains a
// platform-owned component and the allowlist is not updated with it, "platform
// claims exactly the platform set" fails.

@@warning("-44")

open JestGlobals

let tempRoot = (): string =>
  NodeFs.mkdtempSync(NodePath.join([NodeOs.tmpdir(), "reventless-reset-"]))

// Every qdb table a live hybrid store holds.
let platformTables = ["qdb_Plugins", "qdb_UiFragments"]
let catalogTables = ["qdb_Categories", "qdb_ProductDemand", "qdb_Products"]
let orderingTables = ["qdb_AvailableProducts", "qdb_Customers", "qdb_Orders"]
// Claimed by no structure at all — reachable only through a domain-wide scope.
let unclaimedTables = [
  "qdb_AutoShipOrderTodo",
  "qdb_GeocodeCustomerAddressTodo",
  "qdb_ImportProductAudit",
  "qdb_SendOrderConfirmationTodo",
]

let structureJson = (~queryables, ~writables, ~stores) =>
  Dict.fromArray([
    (
      "readModels",
      queryables
      ->Array.map(n => Dict.fromArray([("name", JSON.Encode.string(n))])->JSON.Encode.object)
      ->JSON.Encode.array,
    ),
    ("stateViewSlices", []->JSON.Encode.array),
    (
      "aggregates",
      writables
      ->Array.map(n => Dict.fromArray([("name", JSON.Encode.string(n))])->JSON.Encode.object)
      ->JSON.Encode.array,
    ),
    ("stateChangeSlices", []->JSON.Encode.array),
    ("requiredStores", stores->Array.map(JSON.Encode.string)->JSON.Encode.array),
  ])->JSON.Encode.object

// A store shaped like the live one, with one row in every table so counts are
// non-zero and a plan that claims a table is visible as such.
let makeStore = (): (SqliteDriver.t, string) => {
  let root = tempRoot()
  let db = SqliteDriver.openDb(~path=NodePath.join([root, "local.db"]))

  let allTables = [platformTables, catalogTables, orderingTables, unclaimedTables]->Array.flat
  allTables->Array.forEach(t => {
    db->SqliteDriver.exec(
      `CREATE TABLE ${t} (partition_key TEXT NOT NULL, sub_key TEXT NOT NULL DEFAULT '', item TEXT NOT NULL, expires_at INTEGER, PRIMARY KEY (partition_key, sub_key))`,
    )
    // qdb_Plugins gets the two registry rows below and nothing else, so its count
    // stays the number of connected plugins.
    if t != "qdb_Plugins" {
      db
      ->SqliteDriver.prepare(`INSERT INTO ${t}(partition_key, item) VALUES(?, ?)`)
      ->SqliteDriver.run([JSON.Encode.string("row1"), JSON.Encode.string("{}")])
    }
  })

  db->SqliteDriver.exec(
    "CREATE TABLE event_log (log_name TEXT NOT NULL, aggregate_id TEXT NOT NULL, seq_nr INTEGER NOT NULL, payload TEXT NOT NULL, PRIMARY KEY (log_name, aggregate_id, seq_nr))",
  )
  db->SqliteDriver.exec(
    "CREATE TABLE dcb_event (log_name TEXT NOT NULL, position INTEGER NOT NULL, event_type TEXT NOT NULL, data TEXT NOT NULL, meta TEXT NOT NULL, recorded_at TEXT NOT NULL, PRIMARY KEY (log_name, position))",
  )
  db->SqliteDriver.exec(
    "CREATE TABLE projection_checkpoint (read_model TEXT NOT NULL PRIMARY KEY, position INTEGER NOT NULL)",
  )

  [("PluginAggrEventLog", "plugin1"), ("CustomerAggrEventLog", "cust1")]->Array.forEach(((
    log,
    id,
  )) =>
    db
    ->SqliteDriver.prepare("INSERT INTO event_log VALUES(?, ?, 1, '{}')")
    ->SqliteDriver.run([JSON.Encode.string(log), JSON.Encode.string(id)])
  )
  db
  ->SqliteDriver.prepare("INSERT INTO dcb_event VALUES(?, 1, 'X', '{}', '{}', '')")
  ->SqliteDriver.run([JSON.Encode.string("CatalogDcbEventLog")])

  // All four checkpoint shapes the live store holds.
  [
    "CategoriesEventColl",
    "CustomersReadModelEventColl",
    "UiFragmentsEventColl",
    "PluginsReadModelEventColl",
    "dcb:CategoriesEventColl",
  ]->Array.forEach(rm =>
    db
    ->SqliteDriver.prepare("INSERT INTO projection_checkpoint VALUES(?, 1)")
    ->SqliteDriver.run([JSON.Encode.string(rm)])
  )

  // The registry rows the reset reads its mapping from.
  let plugin = (name, structure) =>
    db
    ->SqliteDriver.prepare("INSERT INTO qdb_Plugins(partition_key, item) VALUES(?, ?)")
    ->SqliteDriver.run([
      JSON.Encode.string(name),
      JSON.Encode.string(
        Dict.fromArray([("structure", structure)])->JSON.Encode.object->JSON.stringify,
      ),
    ])
  plugin(
    "Catalog",
    structureJson(
      ~queryables=["Categories", "ProductDemand", "Products"],
      ~writables=[],
      ~stores=["Catalog.productImages"],
    ),
  )
  plugin(
    "Ordering",
    structureJson(
      ~queryables=["AvailableProducts", "Customers", "Orders"],
      ~writables=["Customer"],
      ~stores=[],
    ),
  )

  (db, root)
}

let labels = (p: LocalSeedReset.plan) => p.items->Array.map(i => i.label)

describe("checkpointComponent", () => {
  testSync("recovers the component from every checkpoint shape the store holds", () => {
    expect(LocalSeedReset.checkpointComponent("CategoriesEventColl"))->toEqual("Categories")
    expect(LocalSeedReset.checkpointComponent("CustomersReadModelEventColl"))->toEqual("Customers")
    expect(LocalSeedReset.checkpointComponent("UiFragmentsEventColl"))->toEqual("UiFragments")
    expect(LocalSeedReset.checkpointComponent("PluginsReadModelEventColl"))->toEqual("Plugins")
    expect(LocalSeedReset.checkpointComponent("dcb:CategoriesEventColl"))->toEqual("Categories")
  })
})

describe("scope classification", () => {
  testSync("domain claims every non-platform table, including what no structure lists", () => {
    let (db, root) = makeStore()
    let plan = LocalSeedReset.build(db, ~root, ~scope=Domain)
    let claimed = labels(plan)

    [catalogTables, orderingTables, unclaimedTables]
    ->Array.flat
    ->Array.forEach(t => expect(claimed->Array.includes(t))->toEqual(true))
    platformTables->Array.forEach(t => expect(claimed->Array.includes(t))->toEqual(false))
    db->SqliteDriver.close
  })

  testSync("domain leaves the plugin registry's own log and the offload store alone", () => {
    let (db, root) = makeStore()
    let claimed = labels(LocalSeedReset.build(db, ~root, ~scope=Domain))
    expect(claimed->Array.includes("event_log (PluginAggrEventLog)"))->toEqual(false)
    expect(claimed->Array.includes("offload/"))->toEqual(false)
    // A domain aggregate's log is claimed.
    expect(claimed->Array.includes("event_log (CustomerAggrEventLog)"))->toEqual(true)
    expect(claimed->Array.includes("dcb_event (CatalogDcbEventLog)"))->toEqual(true)
    db->SqliteDriver.close
  })

  testSync("platform claims exactly the platform set — the allowlist pin", () => {
    let (db, root) = makeStore()
    let claimed = labels(LocalSeedReset.build(db, ~root, ~scope=Platform))
    platformTables->Array.forEach(t => expect(claimed->Array.includes(t))->toEqual(true))
    expect(claimed->Array.includes("event_log (PluginAggrEventLog)"))->toEqual(true)
    [catalogTables, orderingTables, unclaimedTables]
    ->Array.flat
    ->Array.forEach(t => expect(claimed->Array.includes(t))->toEqual(false))
    db->SqliteDriver.close
  })

  testSync("checkpoints follow their component across scopes", () => {
    let (db, root) = makeStore()
    let domain = labels(LocalSeedReset.build(db, ~root, ~scope=Domain))
    expect(domain->Array.includes("projection_checkpoint (CategoriesEventColl)"))->toEqual(true)
    expect(domain->Array.includes("projection_checkpoint (dcb:CategoriesEventColl)"))->toEqual(true)
    expect(domain->Array.includes("projection_checkpoint (UiFragmentsEventColl)"))->toEqual(false)

    let platform = labels(LocalSeedReset.build(db, ~root, ~scope=Platform))
    expect(platform->Array.includes("projection_checkpoint (UiFragmentsEventColl)"))->toEqual(true)
    expect(platform->Array.includes("projection_checkpoint (PluginsReadModelEventColl)"))->toEqual(
      true,
    )
    db->SqliteDriver.close
  })

  testSync("a plugin scope claims only its own components", () => {
    let (db, root) = makeStore()
    let claimed = labels(LocalSeedReset.build(db, ~root, ~scope=OnePlugin("Catalog")))
    catalogTables->Array.forEach(t => expect(claimed->Array.includes(t))->toEqual(true))
    orderingTables->Array.forEach(t => expect(claimed->Array.includes(t))->toEqual(false))
    platformTables->Array.forEach(t => expect(claimed->Array.includes(t))->toEqual(false))
    db->SqliteDriver.close
  })

  testSync("a plugin scope reports only what NO plugin claims, not the other plugin's", () => {
    let (db, root) = makeStore()
    let plan = LocalSeedReset.build(db, ~root, ~scope=OnePlugin("Catalog"))
    expect(plan.unattributed->Array.toSorted(String.compare))->toEqual(unclaimedTables)
    db->SqliteDriver.close
  })
})

describe("execution", () => {
  testSync("emptying the domain scope leaves the platform rows in place", () => {
    let (db, root) = makeStore()
    LocalSeedReset.execute(db, LocalSeedReset.build(db, ~root, ~scope=Domain))

    let count = table =>
      switch db->SqliteDriver.prepare(`SELECT COUNT(*) AS c FROM ${table}`)->SqliteDriver.get([]) {
      | Some(row) =>
        switch row->Dict.get("c") {
        | Some(JSON.Number(n)) => n->Float.toInt
        | _ => -1
        }
      | None => -1
      }

    expect(count("qdb_Categories"))->toEqual(0)
    expect(count("qdb_ImportProductAudit"))->toEqual(0)
    expect(count("qdb_Plugins"))->toEqual(2)
    expect(count("qdb_UiFragments"))->toEqual(1)
    // The registry's own event log survives, so the plugins stay registered.
    expect(count("event_log"))->toEqual(1)
    db->SqliteDriver.close
  })

  testSync("the tables themselves survive — contents are deleted, not dropped", () => {
    let (db, root) = makeStore()
    LocalSeedReset.execute(db, LocalSeedReset.build(db, ~root, ~scope=Everything))
    // A dropped table would make this throw rather than return 0.
    expect(
      db
      ->SqliteDriver.prepare("SELECT COUNT(*) AS c FROM qdb_Categories")
      ->SqliteDriver.get([])
      ->Option.isSome,
    )->toEqual(true)
    db->SqliteDriver.close
  })
})
