module AppSync = QueryDbResolvers_AppSync
module NoOp = QueryDbResolvers_NoOp
module Lambda = QueryDbResolvers_Lambda

// B3.2b: Postgres-backed read models have no DynamoDB data source — their
// GraphQL Query fields are served by the shared PgQueryResolver Lambda data
// source (`QueryDbResolvers_Lambda`, Invoke templates → PgQueryResolver_Lambda).
// DynamoDB-backed (incl. admin-exempt) read models keep the direct resolver set.
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
      QueryDbResolvers_Lambda.make(
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
