// DCB EventLog storage dispatcher.
//
// Selects the concrete backend at `make` time by consulting BackendState:
//   - Sqlite   → DcbEventLogStorage_Sqlite (true DCB semantics on SQL)
//   - Postgres → ReventlessPostgres.DcbEventLogStorage_Postgres (exact DCB
//                semantics: scoped advisory locks + atomic condition check)
//   - Memory   → DcbEventLogStorage_InMemory (pure in-memory)
//
// Registers each backend's read with the Bus so the LocalBus DCB event-tap can
// stream historical events uniformly.

module Make = (Bus: LocalBus.T) => {
  let make: ReventlessCore.DcbEventLog_Adapter.storageMaker = (
    ~name,
    ~indexes,
    ~partitionTag,
    ~crossPartitionTagKeys as _=?,
    ~opts,
  ) => {
    switch (BackendState.getSqliteDb(), BackendState.getPostgresPool()) {
    | (Some(db), _) =>
      let (storageName, read, storage) = DcbEventLogStorage_Sqlite.makeStorage(
        ~db,
        ~name,
        ~indexes,
        ~partitionTag,
        ~opts,
      )
      Bus.registerDcbEventLogRead(storageName, read)
      storage
    | (_, Some(pool)) =>
      let (storageName, ops, storage) = ReventlessPostgres.DcbEventLogStorage_Postgres.makeStorage(
        ~pool,
        ~name,
        ~indexes,
        ~partitionTag,
        ~opts,
      )
      Bus.registerDcbEventLogRead(storageName, ops.read)
      storage
    | (None, None) =>
      let (storageName, read, storage) = DcbEventLogStorage_InMemory.makeStorage(
        ~name,
        ~indexes,
        ~partitionTag,
        ~opts,
      )
      Bus.registerDcbEventLogRead(storageName, read)
      storage
    }
  }
}
