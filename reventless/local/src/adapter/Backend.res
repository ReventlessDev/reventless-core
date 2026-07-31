// Selects which storage backend the in-memory Platform uses.
//
// Memory   — pure in-memory dicts/refs, current default behaviour, wiped on restart.
// Sqlite   — opt-in on-disk SQLite file via SqliteDriver. Survives process restart.
//             resetOnStart=true wipes the file when the Platform is constructed.

type t =
  | Memory
  | Sqlite({path: string, resetOnStart: bool})
  // Carries a live, schema-ensured pool: `pg` has no synchronous client, and
  // Platform.MakeWithConfig is a synchronous functor, so the async setup
  // (connect + ensureSchema + count) is done by the `postgres` smart constructor
  // BEFORE Make. `initialCount` seeds the event-tap counter; `connection` is
  // retained for diagnostics only.
  | Postgres({pool: ReventlessPostgres.PgDriver.pool, initialCount: int, connection: string})

let memory = Memory
let sqlite = (~path, ~resetOnStart=false) => Sqlite({path, resetOnStart})

// Async constructor for the Postgres backend. Connects a pool, ensures the
// schema/functions exist, truncates when resetOnStart, and pre-counts persisted
// events. Await this before Platform.MakeWithConfig:
//   let backend = await Backend.postgres(~connection="postgres://…")
//   module Platform = Platform.MakeWithConfig({ …; let backend })
let postgres = async (~connection, ~resetOnStart=false) => {
  let pool = ReventlessPostgres.PgDriver.makePool({connectionString: connection})
  await ReventlessPostgres.PgSchema.ensureSchema(pool)
  if resetOnStart {
    await ReventlessPostgres.PgSchema.truncateAll(pool)
  }
  let initialCount =
    (await ReventlessPostgres.EventLogStorage_Postgres.countAll(pool)) +
      (await ReventlessPostgres.DcbEventLogStorage_Postgres.countAll(pool))
  Postgres({pool, initialCount, connection})
}


// Deletes a file if it exists. No-op if the path is missing.

let removeFileIfExists = (path: string) =>
  try NodeFs.unlinkSync(path) catch {
  | _ => ()
  }

// Parses REVENTLESS_LOCAL_BACKEND. Recognised forms:
//   sqlite:./local.db        — Sqlite backend, no reset on start
//   sqlite:./local.db?reset  — Sqlite backend, wipes file at Platform.Make time
//   memory                   — explicit Memory selector
// Anything else (including unset) yields Memory.
let fromEnv = () =>
  switch NodeProcess.env->Dict.get("REVENTLESS_LOCAL_BACKEND") {
  | None => Memory
  | Some(raw) =>
    let trimmed = raw->String.trim
    if trimmed == "" || trimmed == "memory" {
      Memory
    } else if trimmed->String.startsWith("sqlite:") {
      let rest = trimmed->String.slice(~start=String.length("sqlite:"), ~end=String.length(trimmed))
      let (path, resetOnStart) = switch rest->String.split("?") {
      | [p, q] => (p, q->String.split("&")->Array.includes("reset"))
      | _ => (rest, false)
      }
      Sqlite({path, resetOnStart})
    } else {
      Memory
    }
  }
