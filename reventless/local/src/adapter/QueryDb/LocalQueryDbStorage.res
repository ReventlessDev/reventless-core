// QueryDb storage dispatcher.
//
// Selects the concrete backend at `make` time by consulting BackendState:
//   - Sqlite → QueryDbStorage_Sqlite (JSON tables + json_extract indexes)
//   - Memory → QueryDbStorage_InMemory (pure in-memory, Bus-registered)
//
// Postgres note: the LocalBus scan/stream/index registrations are SYNCHRONOUS
// (`unit => array<JSON.t>`), which async pg cannot satisfy without a broader bus
// refactor. So under Backend.Postgres the read-model live-query path uses the
// in-memory arm (getDb() is None for Postgres → Memory), rebuilt by replay from
// the durable pg event log; the deploy-usable ReventlessPostgres.QueryDbStorage_Postgres
// serves non-local compute layers. See docs/plans/postgres-storage-adapter.md §E.

module Make = (Bus: LocalBus.T) => {
  module Mem = QueryDbStorage_InMemory.Make(Bus)

  type api = unit
  type role = unit

  let sqliteBusCallbacks: QueryDbStorage_Sqlite.busCallbacks = {
    publishStateChange: Bus.publishStateChange,
    registerQueryDb: Bus.registerQueryDb,
    registerQueryDbScan: Bus.registerQueryDbScan,
    registerQueryDbStream: Bus.registerQueryDbStream,
    registerQueryDbIndexLookup: Bus.registerQueryDbIndexLookup,
    registerQueryDbListPage: Bus.registerQueryDbListPage,
  }

  let make: ReventlessCore.QueryDb_Adapter.storageMaker<unit, unit> = (
    ~name,
    ~indexes,
    ~subIdField=?,
    ~ttl=?,
    ~api,
    ~apiRole,
    ~owner as _=?, ~opts,
  ) =>
    switch BackendState.getSqliteDb() {
    | Some(db) =>
      QueryDbStorage_Sqlite.makeStorage(~db, ~bus=sqliteBusCallbacks, ~name, ~indexes, ~subIdField)
    | None => Mem.make(~name, ~indexes, ~subIdField?, ~ttl?, ~api, ~apiRole, ~opts)
    }
}
