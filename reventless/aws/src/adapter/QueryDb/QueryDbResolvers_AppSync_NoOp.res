// No-op AppSync resolver adapter — creates no resolvers.
// Used for admin-internal read models (e.g. Plugin) that have a DynamoDB QueryDb
// but no AppSync query fields (accessed only via queryEngine at runtime).
type api = Types.AppSync.api
type role = Types.AppSync.role

let make: ReventlessCore.QueryDb_Adapter.resolversMaker<api, role> = (
  ~name as _,
  ~api as _,
  ~apiRole as _,
  ~dataSourceName as _,
  ~indexes as _,
  ~subIdField as _,
  ~idResolverConfigs as _,
  ~idsResolverConfigs as _,
  ~authorization as _: Reventless.Authorization.permission,
  ~opts as _,
) => {
  resources: [],
  resourcesMaker: _ => [],
}
