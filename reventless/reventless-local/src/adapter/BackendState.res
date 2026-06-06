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

let current: ref<active> = ref(Memory)

let setMemory = () => current := Memory

let setSqlite = (~db, ~path) => current := Sqlite({db, path})

let getDb = () =>
  switch current.contents {
  | Sqlite({db}) => Some(db)
  | Memory => None
  }

// True when the active backend is SQLite — used by adapters that want to swap
// their implementation entirely, not just their data access.
let isSqlite = () =>
  switch current.contents {
  | Sqlite(_) => true
  | Memory => false
  }
