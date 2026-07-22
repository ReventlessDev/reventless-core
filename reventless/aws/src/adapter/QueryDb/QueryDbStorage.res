let name = "QueryDbStorage"

module DynamoDb = QueryDbStorage_DynamoDb
module DynamoDbStream = QueryDbStorage_DynamoDbStream
module DynamoDb_Runtime = QueryDbStorage_DynamoDb_Runtime
module Postgres = QueryDbStorage_Postgres

// Build-time QueryDb storage selectors (B3.1). Read `QueryDbBackend` — set by the
// platform when a `PgConnection` is supplied — and dispatch per read model:
// Postgres (no table, no data source) unless the name is admin-exempt. The Stream
// selector falls back to the streamed DynamoDB maker; on Postgres there is no
// stream, so live updates (B3.3) are published from the projection Lambda after
// each save/delete instead. SelectableStream records subscription-enabled
// Postgres read models in `QueryDbBackend.postgresStreamRegistry` (a leaf module,
// to avoid a build cycle) so the projection-Lambda runtime builder knows which
// handlers need the AppSync-Events publish wiring.
module Selectable = {
  type api = QueryDbStorage_Postgres.api
  type role = QueryDbStorage_Postgres.role
  let make: ReventlessCore.QueryDb_Adapter.storageMaker<api, role> = (
    ~name,
    ~indexes,
    ~subIdField=?,
    ~ttl=?,
    ~api,
    ~apiRole,
    ~owner, ~opts,
  ) =>
    if QueryDbBackend.isPostgresFor(name) {
      Postgres.make(~name, ~indexes, ~subIdField?, ~ttl?, ~api, ~apiRole, ~owner, ~opts)
    } else {
      DynamoDb.make(~name, ~indexes, ~subIdField?, ~ttl?, ~api, ~apiRole, ~owner, ~opts)
    }
}

module SelectableStream = {
  type api = QueryDbStorage_Postgres.api
  type role = QueryDbStorage_Postgres.role
  let make: ReventlessCore.QueryDb_Adapter.storageMaker<api, role> = (
    ~name,
    ~indexes,
    ~subIdField=?,
    ~ttl=?,
    ~api,
    ~apiRole,
    ~owner, ~opts,
  ) =>
    if QueryDbBackend.isPostgresFor(name) {
      QueryDbBackend.postgresStreamRegistry->Set.add(name)
      Postgres.make(~name, ~indexes, ~subIdField?, ~ttl?, ~api, ~apiRole, ~owner, ~opts)
    } else {
      DynamoDbStream.make(~name, ~indexes, ~subIdField?, ~ttl?, ~api, ~apiRole, ~owner, ~opts)
    }
}
