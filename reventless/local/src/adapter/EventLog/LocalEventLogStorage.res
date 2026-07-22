// EventLog storage dispatcher.
//
// Selects the concrete backend at `make` time by consulting BackendState, so the
// core EventLog builder wires a single storageMaker module regardless of backend:
//   - Sqlite   → EventLogStorage_Sqlite (on-disk / :memory:)
//   - Postgres → ReventlessPostgres.EventLogStorage_Postgres (durable, async)
//   - Memory   → EventLogStorage_InMemory (pure in-memory)
//
// The `Make(Bus)` functor also registers each backend's replay with the Bus so
// the LocalBus event-tap can stream historical events uniformly.

module Make = (Bus: LocalBus.T) => {
  let make: ReventlessCore.EventLog_Adapter.storageMaker = (~name, ~owner, ~opts) => {
    switch (BackendState.getSqliteDb(), BackendState.getPostgresPool()) {
    | (Some(db), _) =>
      let (storageName, replay, storage) = EventLogStorage_Sqlite.makeStorage(~db, ~name, ~opts)
      Bus.registerEventLogReplay(storageName, replay)
      storage
    | (_, Some(pool)) =>
      let (storageName, ops, storage) = ReventlessPostgres.EventLogStorage_Postgres.makeStorage(
        ~pool,
        ~name,
        ~opts,
      )
      Bus.registerEventLogReplay(storageName, ops.replay)
      storage
    | (None, None) =>
      let (storageName, replay, storage) = EventLogStorage_InMemory.makeMemoryStorage(~name, ~opts)
      Bus.registerEventLogReplay(storageName, replay)
      storage
    }
  }
}
