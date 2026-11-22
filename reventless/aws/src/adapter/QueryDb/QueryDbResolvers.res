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
      let onPluginApi = () =>
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
      switch authorization {
      // A view for visitors is served by the narrow API: the same resolvers, on
      // a data source of that API which may only read the view's table. Decided
      // when the resolvers are made, by which time that API exists.
      | AllowAnonymous if AppSync_VisitorApi.hosted() => {
          resources: [],
          resourcesMaker: allQueryDbs =>
            switch AppSync_VisitorApi.made() {
            | None => onPluginApi().resourcesMaker(allQueryDbs)
            | Some(visitors) =>
              let table =
                allQueryDbs
                ->ReventlessCore.Plugin_Helpers.getStorageResources(None, name->String.capitalize)
                ->Util.DynamoDb.findResourceInOutput
                ->ReventlessCore.Adapter.outputToResource
              let dataSource = AppSync_VisitorView.dataSource(
                ~name=name->String.capitalize,
                ~visitors,
                ~tableName=table.name,
                ~opts,
              )
              QueryDbResolvers_AppSync.make(
                ~name,
                ~api=visitors.api,
                ~apiRole=visitors.role,
                ~dataSourceName=dataSource,
                ~indexes,
                ~subIdField,
                ~idResolverConfigs,
                ~idsResolverConfigs,
                ~authorization,
                ~opts,
              ).resourcesMaker(allQueryDbs)
            },
        }
      | _ => onPluginApi()
      }
    }
}
