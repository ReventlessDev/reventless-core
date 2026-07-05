module AppSync = QueryDbResolvers_AppSync
module NoOp = QueryDbResolvers_NoOp

// B3.1: Postgres-backed read models have no DynamoDB data source — suppress the
// direct AppSync resolvers (their GraphQL fields stay unresolved until B3.2's
// Lambda data source). DynamoDB-backed (incl. admin-exempt) read models keep the
// full resolver set.
module Selectable = {
  type api = QueryDbResolvers_AppSync_NoOp.api
  type role = QueryDbResolvers_AppSync_NoOp.role
  let make: ReventlessCore.QueryDb_Adapter.resolversMaker<api, role> = (
    ~name,
    ~api,
    ~apiRole,
    ~dataSourceName,
    ~indexes,
    ~subIdField,
    ~idResolverConfigs,
    ~idsResolverConfigs,
    ~authorization,
    ~opts,
  ) =>
    if QueryDbBackend.isPostgresFor(name) {
      QueryDbResolvers_AppSync_NoOp.make(
        ~name,
        ~api,
        ~apiRole,
        ~dataSourceName,
        ~indexes,
        ~subIdField,
        ~idResolverConfigs,
        ~idsResolverConfigs,
        ~authorization,
        ~opts,
      )
    } else {
      QueryDbResolvers_AppSync.make(
        ~name,
        ~api,
        ~apiRole,
        ~dataSourceName,
        ~indexes,
        ~subIdField,
        ~idResolverConfigs,
        ~idsResolverConfigs,
        ~authorization,
        ~opts,
      )
    }
}
