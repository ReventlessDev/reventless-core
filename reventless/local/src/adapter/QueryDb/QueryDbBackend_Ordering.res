/** How the read models' store orders a list under this backend. Read models live in SQLite under
    `Sqlite` and in memory under the others, `Postgres` included. */
let forBackend = (backend: Backend.t): ReventlessCore.QueryDb_Ordering.t =>
  switch backend {
  | Sqlite(_) => QueryDbStorage_Sqlite.ordering
  | Memory | Postgres(_) => QueryDbStorage_InMemory.ordering
  }
