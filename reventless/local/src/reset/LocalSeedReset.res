// Scoped, in-place reset of a local platform's store — the local counterpart of
// `ReventlessSeedAws_Reset`, and the inverse of `pnpm run seed`:
// `Seed.Runner.assertStoreEmpty` refuses to seed a non-empty store, and this makes
// a non-empty store empty again.
//
// Two properties it takes from the deployed version and one it does not need:
//
//   • It EMPTIES, it does not destroy. AWS never drops a table, it deletes rows.
//     Deleting `.reventless/local.db` is not the local analogue — and while the
//     platform runs it is actively wrong: the process holds the file open, so the
//     unlink leaves it on the orphaned inode still serving every row it had, the
//     delete looks like it worked, and the seed then fails against the untouched
//     server with "the target store is not empty". Deleting ROWS through a second
//     connection is visible to the running server immediately (its reads go to
//     these tables; there is no in-process cache), so a reset needs no restart and
//     no stopping of the platform.
//
//   • It is SCOPED. Wiping domain data leaves the plugin registry intact, so a
//     re-seed just works — the same reason the deployed default is `domain`.
//
//   • It needs none of AWS's gates (name allowlist, `wipeable` flag, tag-scoped
//     discovery, typed confirm). Those exist because that target is remote, shared
//     and irreversible; this one is a file in a git-ignored directory that
//     `serve:reset` already wipes without ceremony. A printed plan and one y/N is
//     the proportionate equivalent.
//
// ── Why classification is discovery-first ──────────────────────────────────
//
// The obvious design — read each connected plugin's `pluginStructure` and wipe what
// it lists — under-deletes, measurably. In the hybrid example the store holds
// `qdb_ImportProductAudit` and three `*Todo` tables that appear in NO structure's
// arrays, and `Platform_Admin_Structure` does not mention `qdb_UiFragments` either.
// So neither "domain = what the plugins claim" nor "platform = the remainder" is
// sound.
//
// Instead: discover what is actually in the store, classify against a CLOSED
// platform allowlist, and let domain be everything else. That polarity is the point
// — a reset that misses domain rows fails the re-seed it exists to enable, while one
// that catches an unexpected domain table does what the operator asked. Per-plugin
// scope attributes positively from that plugin's structure and REPORTS what it
// cannot attribute, rather than guessing either way.

open ReventlessSeed

// ── Scope ───────────────────────────────────────────────────────────────────

type scope =
  | Domain
  | Platform
  | Everything
  | OnePlugin(string)

let scopeLabel = (s: scope) =>
  switch s {
  | Domain => "domain"
  | Platform => "platform"
  | Everything => "everything"
  | OnePlugin(p) => p
  }

// ── The platform's own components ───────────────────────────────────────────
//
// A closed set, taken from core's constants rather than spelled as literals so it
// moves when core does. `qdb_UiFragments` is here because the UI fragment registry
// is platform-owned even though the platform's structure omits it — the omission
// this list exists to survive. LocalSeedResetTest's "platform claims exactly the
// platform set" is the pin: it fails if core gains a platform-owned component and
// this list is not updated with it.

let platformQueryables = [ReventlessCore.PluginsReadModelSpec.name, ReventlessCore.UiFragments.name]

let platformWritables = [ReventlessCore.PluginSpec.name]

// `Categories` → `qdb_Categories`, matching QueryDbStorage_Sqlite.tableName.
let qdbTableName = (name: string): string => "qdb_" ++ name->String.replaceAll("-", "_")

// `Plugin` → `PluginAggrEventLog`, matching the Bus key an aggregate's event log
// takes (ComponentType.name applied twice).
let aggregateLogName = (name: string): string =>
  ReventlessCore.ComponentType.name(ReventlessCore.ComponentType.name(name, Aggregate), EventLog)

// A checkpoint row belongs to the component whose events it tracks, but its key is
// not reconstructible from the component name: all of `CategoriesEventColl`,
// `CustomersReadModelEventColl`, `UiFragmentsEventColl` and
// `PluginsReadModelEventColl` occur, so the `ReadModel` infix is present for some
// components and absent for others. Strip instead of build: drop a leading `dcb:`,
// a trailing `EventColl`, then a trailing `ReadModel`, and match what remains.
let checkpointComponent = (readModel: string): string => {
  let withoutDcb =
    readModel->String.startsWith("dcb:")
      ? readModel->String.slice(~start=String.length("dcb:"), ~end=readModel->String.length)
      : readModel
  let withoutColl =
    withoutDcb->String.endsWith("EventColl")
      ? withoutDcb->String.slice(
          ~start=0,
          ~end=withoutDcb->String.length - String.length("EventColl"),
        )
      : withoutDcb
  withoutColl->String.endsWith("ReadModel")
    ? withoutColl->String.slice(
        ~start=0,
        ~end=withoutColl->String.length - String.length("ReadModel"),
      )
    : withoutColl
}

// ── Discovery ───────────────────────────────────────────────────────────────

let tableExists = (db, name) =>
  db
  ->SqliteDriver.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name = ?")
  ->SqliteDriver.get([JSON.Encode.string(name)])
  ->Option.isSome

let strings = (rows: array<dict<JSON.t>>, column: string): array<string> =>
  rows->Array.filterMap(row =>
    switch row->Dict.get(column) {
    | Some(JSON.String(s)) => Some(s)
    | _ => None
    }
  )

let qdbTables = (db): array<string> =>
  db
  ->SqliteDriver.prepare(
    "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'qdb\\_%' ESCAPE '\\' ORDER BY name",
  )
  ->SqliteDriver.all([])
  ->strings("name")

let distinct = (db, ~table, ~column): array<string> =>
  tableExists(db, table)
    ? db
      ->SqliteDriver.prepare(`SELECT DISTINCT ${column} AS v FROM ${table} ORDER BY v`)
      ->SqliteDriver.all([])
      ->strings("v")
    : []

let countWhere = (db, ~table, ~column, ~value): int =>
  if !tableExists(db, table) {
    0
  } else {
    switch db
    ->SqliteDriver.prepare(`SELECT COUNT(*) AS c FROM ${table} WHERE ${column} = ?`)
    ->SqliteDriver.get([JSON.Encode.string(value)]) {
    | Some(row) =>
      switch row->Dict.get("c") {
      | Some(JSON.Number(n)) => n->Float.toInt
      | _ => 0
      }
    | None => 0
    }
  }

let countAll = (db, ~table): int =>
  if !tableExists(db, table) {
    0
  } else {
    switch db->SqliteDriver.prepare(`SELECT COUNT(*) AS c FROM ${table}`)->SqliteDriver.get([]) {
    | Some(row) =>
      switch row->Dict.get("c") {
      | Some(JSON.Number(n)) => n->Float.toInt
      | _ => 0
      }
    | None => 0
    }
  }

// ── Plugin structures ───────────────────────────────────────────────────────
//
// Read field-by-field rather than decoded through `pluginStructureSchema`: only the
// component names are needed, and a strict decode would make an unrelated schema
// addition break the reset for a store written before it. `Message.parseJsonTolerant`
// heals a stale event on the read path; a maintenance tool can simply not depend on
// the parts it does not read.

type pluginComponents = {
  plugin: string,
  queryables: array<string>,
  writables: array<string>,
  stores: array<string>,
}

let namesIn = (structure: dict<JSON.t>, field: string): array<string> =>
  switch structure->Dict.get(field) {
  | Some(JSON.Array(items)) =>
    items->Array.filterMap(item =>
      switch item {
      | JSON.Object(o) =>
        switch o->Dict.get("name") {
        | Some(JSON.String(s)) => Some(s)
        | _ => None
        }
      | _ => None
      }
    )
  | _ => []
  }

// `structure` is inline or an `{$offload: {key, …}}` reference into the object
// store — the same field the ComponentDefinitions Lambda resolves from S3 on the
// deployed side, resolved here from `offload/`.
let resolveStructure = (~root: string, json: JSON.t): option<dict<JSON.t>> =>
  switch json {
  | JSON.Object(o) =>
    switch o->Dict.get(Reventless.Offload.sentinelKey) {
    | Some(JSON.Object(ref)) =>
      switch ref->Dict.get("key") {
      | Some(JSON.String(key)) =>
        ObjectStoreStorage_FileSystem.getOffload(~root, ~key)->Option.flatMap(bytes =>
          switch try bytes->JSON.parseOrThrow catch {
          | _ => JSON.Encode.null
          } {
          | JSON.Object(resolved) => Some(resolved)
          | _ => None
          }
        )
      | _ => None
      }
    | _ => Some(o)
    }
  | _ => None
  }

let readPlugins = (db, ~root: string): array<pluginComponents> => {
  let table = qdbTableName(ReventlessCore.PluginsReadModelSpec.name)
  if !tableExists(db, table) {
    []
  } else {
    db
    ->SqliteDriver.prepare(`SELECT partition_key, item FROM ${table}`)
    ->SqliteDriver.all([])
    ->Array.filterMap(row =>
      switch (row->Dict.get("partition_key"), row->Dict.get("item")) {
      | (Some(JSON.String(plugin)), Some(JSON.String(item))) =>
        switch try item->JSON.parseOrThrow catch {
        | _ => JSON.Encode.null
        } {
        | JSON.Object(o) =>
          o
          ->Dict.get("structure")
          ->Option.flatMap(s => resolveStructure(~root, s))
          ->Option.map(structure => {
            plugin,
            queryables: Array.concat(
              namesIn(structure, "readModels"),
              namesIn(structure, "stateViewSlices"),
            ),
            writables: Array.concat(
              namesIn(structure, "aggregates"),
              namesIn(structure, "stateChangeSlices"),
            ),
            stores: switch structure->Dict.get("requiredStores") {
            | Some(JSON.Array(items)) =>
              items->Array.filterMap(
                i =>
                  switch i {
                  | JSON.String(s) => Some(s)
                  | _ => None
                  },
              )
            | _ => []
            },
          })
        | _ => None
        }
      | _ => None
      }
    )
  }
}

// ── The plan ────────────────────────────────────────────────────────────────

type item = {label: string, count: int, run: unit => unit}

type plan = {
  scope: scope,
  items: array<item>,
  /** Discovered components no plugin structure claims, under a per-plugin scope.
      Reported, never silently swept in or left out. */
  unattributed: array<string>,
}

let total = (p: plan) => p.items->Array.reduce(0, (sum, i) => sum + i.count)

let deleteWhere = (db, ~table, ~column, ~value) =>
  if tableExists(db, table) {
    db
    ->SqliteDriver.prepare(`DELETE FROM ${table} WHERE ${column} = ?`)
    ->SqliteDriver.run([JSON.Encode.string(value)])
  }

let clearTable = (db, ~table) =>
  if tableExists(db, table) {
    // Contents, never DROP: the running platform holds prepared statements and
    // indexes against these tables.
    db->SqliteDriver.exec(`DELETE FROM ${table}`)
  }

let build = (db, ~root: string, ~scope: scope): plan => {
  let plugins = readPlugins(db, ~root)

  let platformQdb = platformQueryables->Array.map(qdbTableName)
  let platformLogs = platformWritables->Array.map(aggregateLogName)
  let isPlatformQdb = t => platformQdb->Array.includes(t)
  let isPlatformLog = l => platformLogs->Array.includes(l)

  let selectedPlugins = switch scope {
  | OnePlugin(name) => plugins->Array.filter(p => p.plugin == name)
  | Domain | Everything => plugins
  | Platform => []
  }

  // Which discovered tables/logs this scope claims.
  let claimsQdb = (table: string) =>
    switch scope {
    | Platform => isPlatformQdb(table)
    | Everything => true
    | Domain => !isPlatformQdb(table)
    | OnePlugin(_) =>
      selectedPlugins->Array.some(p => p.queryables->Array.some(q => qdbTableName(q) == table))
    }

  let claimsLog = (log: string) =>
    switch scope {
    | Platform => isPlatformLog(log)
    | Everything => true
    | Domain => !isPlatformLog(log)
    | OnePlugin(_) =>
      selectedPlugins->Array.some(p =>
        p.writables->Array.some(w => aggregateLogName(w) == log || w == log)
      )
    }

  let claimedQdb = qdbTables(db)->Array.filter(claimsQdb)
  let claimedComponents =
    claimedQdb->Array.map(t => t->String.slice(~start=String.length("qdb_"), ~end=t->String.length))

  let items = []

  claimedQdb->Array.forEach(table =>
    items->Array.push({
      label: table,
      count: countAll(db, ~table),
      run: () => clearTable(db, ~table),
    })
  )

  // Event logs and their snapshots move together: leaving a snapshot behind
  // strands the aggregate on state whose events are gone.
  ["event_log", "snapshot"]->Array.forEach(table =>
    distinct(db, ~table, ~column="log_name")
    ->Array.filter(claimsLog)
    ->Array.forEach(log =>
      items->Array.push({
        label: `${table} (${log})`,
        count: countWhere(db, ~table, ~column="log_name", ~value=log),
        run: () => deleteWhere(db, ~table, ~column="log_name", ~value=log),
      })
    )
  )

  ["dcb_event", "dcb_tag"]->Array.forEach(table =>
    distinct(db, ~table, ~column="log_name")
    ->Array.filter(claimsLog)
    ->Array.forEach(log =>
      items->Array.push({
        label: `${table} (${log})`,
        count: countWhere(db, ~table, ~column="log_name", ~value=log),
        run: () => deleteWhere(db, ~table, ~column="log_name", ~value=log),
      })
    )
  )

  // A checkpoint without its read model's rows would stop the re-seeded events
  // ever being projected.
  distinct(db, ~table="projection_checkpoint", ~column="read_model")
  ->Array.filter(rm => claimedComponents->Array.includes(checkpointComponent(rm)))
  ->Array.forEach(rm =>
    items->Array.push({
      label: `projection_checkpoint (${rm})`,
      count: countWhere(db, ~table="projection_checkpoint", ~column="read_model", ~value=rm),
      run: () => deleteWhere(db, ~table="projection_checkpoint", ~column="read_model", ~value=rm),
    })
  )

  // Objects, by the prefix their declaring store roots them at — the local
  // equivalent of the deployed reset's prefix-scoped bucket wipe.
  let claimedPrefixes = switch scope {
  | Platform => []
  | Everything | Domain =>
    // Every prefix present, declared or not: an object under `uploads/` was minted
    // before its store declared a prefix (or by a plugin that declares none), and
    // it is domain data either way.
    ObjectStoreStorage_FileSystem.topLevelPrefixes(~root)
  | OnePlugin(_) =>
    selectedPlugins->Array.flatMap(p =>
      p.stores->Array.map(qualified => LocalObjectStore.localPrefixFor(~qualified))
    )
  }
  claimedPrefixes->Array.forEach(prefix => {
    let count = ObjectStoreStorage_FileSystem.keysUnder(~root, ~prefix)->Array.length
    if count > 0 {
      items->Array.push({
        label: `objects/${prefix}/`,
        count,
        run: () => ObjectStoreStorage_FileSystem.deleteUnder(~root, ~prefix)->ignore,
      })
    }
  })

  // Offloaded payloads are the platform's own store (plugin definitions), so they
  // go with the registry that references them and never with a domain wipe.
  switch scope {
  | Platform | Everything =>
    let count = ObjectStoreStorage_FileSystem.offloadKeys(~root)->Array.length
    if count > 0 {
      items->Array.push({
        label: "offload/",
        count,
        run: () => ObjectStoreStorage_FileSystem.deleteOffloadAll(~root)->ignore,
      })
    }
  | Domain | OnePlugin(_) => ()
  }

  // Under a per-plugin scope, say what NO plugin's structure claims — not merely
  // what falls outside this scope. Another plugin's tables are attributed, just not
  // selected, and listing them here would read as a gap in the tool rather than a
  // narrower scope. What is left is the genuinely unclaimable: components no
  // structure mentions, which only a `domain` scope reaches.
  let unattributed = switch scope {
  | OnePlugin(_) =>
    let claimedByAnyPlugin =
      plugins->Array.flatMap(p => p.queryables->Array.map(qdbTableName))
    qdbTables(db)->Array.filter(t =>
      !isPlatformQdb(t) && !(claimedByAnyPlugin->Array.includes(t))
    )
  | Domain | Platform | Everything => []
  }

  {scope, items, unattributed}
}

// ── Reporting and execution ─────────────────────────────────────────────────

let describe = (p: plan): unit => {
  Console.log("")
  Console.log(`Reset scope: ${p.scope->scopeLabel}`)
  Console.log("")
  if p.items->Array.length == 0 {
    Console.log("  (nothing — this scope already reads empty)")
  } else {
    p.items->Array.forEach(i =>
      Console.log(`  ${i.count->Int.toString->String.padStart(7, " ")}  ${i.label}`)
    )
  }
  if p.unattributed->Array.length > 0 {
    Console.log("")
    Console.log(`  Left alone — no connected plugin's structure claims them (widen the scope to include them):`)
    p.unattributed->Array.forEach(t => Console.log(`    ${t}`))
  }
  Console.log("")
}

let execute = (db, p: plan): unit =>
  db->SqliteDriver.transaction(() => p.items->Array.forEach(i => i.run()))

// ── Entry point ─────────────────────────────────────────────────────────────

let scopeOptions = (plugins: array<string>): array<(string, scope)> =>
  Array.concat(
    Array.concat([("domain", Domain)], plugins->Array.map(p => (p, OnePlugin(p)))),
    [("platform", Platform), ("everything", Everything)],
  )

/** Runs the reset against the store the selected platform actually opened.

    Resolution order, and why it is this way round: the store used to be read off
    `REVENTLESS_LOCAL_BACKEND` in THIS process, which describes no platform at
    all. With a second platform up — the VS Code runner beside a hand-started one
    — that emptied a database nobody was serving while reporting success, and the
    `seed` that follows then refused because the served store was still full. So
    the running platform is asked instead, and the variable is kept only for the
    case discovery cannot serve: a store whose platform is down.

    1. `~dbPath` — a programmatic caller has already decided.
    2. `REVENTLESS_LOCAL_BACKEND` **set in this shell** — an explicit target.
    3. the platform selected by {!LocalSeedTarget.select} — the normal path.

    Note for callers wiring this into a package script: do NOT default the
    variable there (`${REVENTLESS_LOCAL_BACKEND:-sqlite:./…}`). It would make
    step 2 always fire, and that default is the very guess this replaces. */
let run = (~dbPath: option<string>=?): unit => {
  let go = async () => {
    let fromBackendEnv = () =>
      switch Backend.fromEnv() {
      | Backend.Sqlite({path}) if path != ":memory:" => Ok(path)
      | Backend.Sqlite(_) | Backend.Memory =>
        Error(
          "REVENTLESS_LOCAL_BACKEND selects an in-memory store, which a restart already empties.",
        )
      | Backend.Postgres(_) =>
        Error(
          "the Postgres backend keeps its event logs off this machine. Reset it against the database.",
        )
      }

    let resolved = switch (dbPath, Seed.Prompt.envValue("REVENTLESS_LOCAL_BACKEND")) {
    | (Some(p), _) => Ok(p)
    | (None, Some(_)) => fromBackendEnv()
    | (None, None) =>
      let target = await LocalSeedTarget.select()
      target->LocalSeedTarget.announce
      target->LocalSeedTarget.storePath
    }

    let resolved = switch resolved {
    | Ok(path) => Some(path)
    | Error(reason) =>
      Console.log(`Nothing to reset — ${reason}`)
      None
    }

    switch resolved {
    | None => ()
    | Some(path) =>
      if !NodeFs.existsSync(path) {
        Console.log(`Nothing to reset — no store at ${path}.`)
      } else {
        let root = NodePath.dirname(path)
        let db = SqliteDriver.openDb(~path)
        let plugins = readPlugins(db, ~root)->Array.map(p => p.plugin)
        let scope = await Seed.Prompt.select(
          ~title="Reset scope:",
          ~options=scopeOptions(plugins),
          ~env="SEED_RESET_SCOPE",
        )
        let plan = build(db, ~root, ~scope)
        describe(plan)
        if total(plan) == 0 {
          Console.log("Nothing to do.")
        } else {
          let confirmed = switch Seed.Prompt.envValue("SEED_RESET_CONFIRM") {
          | Some("1") | Some("yes") => true
          | _ =>
            let answer = await Seed.Prompt.ask(
              `Empty ${total(
                  plan,
                )->Int.toString} row(s)/object(s) in the "${plan.scope->scopeLabel}" scope? [y/N]: `,
            )
            answer->String.trim->String.toLowerCase == "y"
          }
          if confirmed {
            execute(db, plan)
            Console.log(
              `Reset complete — the "${plan.scope->scopeLabel}" scope reads empty and is re-seedable.`,
            )
          } else {
            Console.log("Nothing was deleted.")
          }
        }
        Seed.Prompt.close()
        db->SqliteDriver.close
      }
    }
  }
  // Kicking a top-level async body off from a `unit` entry point, as the seed
  // harness and the deployed reset both do — the one place the floating promise
  // is the interface rather than an oversight.
  go()->ignore
}
