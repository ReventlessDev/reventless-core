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
// serves non-local compute layers. See docs/plans/done/postgres-storage-adapter.md §E.

// The system that made each read model, by its name. One local platform keeps a read model's
// rows, its bus registration and its catch-up point by its name alone, so two systems' read
// models of one name would write into each other's rows; deployed, each system has its own
// tables and they never meet. The platform refuses to start rather than mix them.
let madeBy: dict<string> = Dict.make()

/** Why a read model of this name cannot be made in `plugin`: another system made one. */
let sharedNameProblem = (~name: string, ~plugin: option<string>): option<string> =>
  switch (plugin, madeBy->Dict.get(name)) {
  | (Some(p), Some(other)) if other != p =>
    Some(
      `${other} and ${p} each have a read model called ${name}. One local platform keeps a read model's rows by its name, so the two would overwrite each other's: rename one of them.`,
    )
  | _ => None
  }

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
    ~owner,
    ~opts,
  ) => {
    let plugin = ReventlessCore.ResourceAttribution.current.contents.plugin
    sharedNameProblem(~name, ~plugin)->Option.forEach(JsError.throwWithMessage)
    plugin->Option.forEach(p => madeBy->Dict.set(name, p))
    switch BackendState.getSqliteDb() {
    | Some(db) =>
      QueryDbStorage_Sqlite.makeStorage(~db, ~bus=sqliteBusCallbacks, ~name, ~indexes, ~subIdField)
    | None => Mem.make(~name, ~indexes, ~subIdField?, ~ttl?, ~api, ~apiRole, ~owner, ~opts)
    }
  }
}
