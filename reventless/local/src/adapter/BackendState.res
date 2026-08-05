// Module-level state for the active storage backend.
//
// Platform.MakeWithConfig sets this once at construction based on Backend.t.
// Downstream adapters (EventLogStorage_InMemory, QueryDbStorage_InMemory, ...)
// read it inside their `make` to decide whether to allocate an in-memory dict
// or delegate to the SQLite-backed implementation.
//
// This trick exists because the core builder functors accept a single
// storageMaker module; we dispatch at runtime instead of at functor-application
// time so callers don't need to pick a builder per backend.

type active =
  | Memory
  | Sqlite({db: SqliteDriver.t, path: string})
  | Postgres({pool: ReventlessPostgres.PgDriver.pool})

let current: ref<active> = ref(Memory)

let setMemory = () => current := Memory

let setSqlite = (~db, ~path) => current := Sqlite({db, path})

let setPostgres = (~pool) => current := Postgres({pool: pool})

// Per-backend handle accessors, symmetric across the SQL backends: each returns
// Some only when that backend is active. Dispatching adapters
// (LocalEventLogStorage, LocalDcbEventLogStorage, LocalQueryDbStorage,
// LocalTaskBucket) switch on these to select their concrete implementation.
let getSqliteDb = () =>
  switch current.contents {
  | Sqlite({db}) => Some(db)
  | Memory | Postgres(_) => None
  }

let getPostgresPool = () =>
  switch current.contents {
  | Postgres({pool}) => Some(pool)
  | Memory | Sqlite(_) => None
  }

// Directory the object store persists under, derived from the SQLite file's own
// directory (`./.reventless/local.db` → `./.reventless`) so uploaded bytes and
// offloaded payloads live and die with the events that reference them. None for
// the backends with nothing durable on this disk: Memory, an in-process
// `:memory:` SQLite, and Postgres — durable, but off-machine, and a connection
// string names no local directory to anchor to, so its object store stays
// in-process.
let getObjectStoreRoot = () =>
  switch current.contents {
  | Sqlite({path}) if path != ":memory:" => Some(NodePath.dirname(path))
  | Sqlite(_) | Memory | Postgres(_) => None
  }
