open Reventless.ReadModel

type operations = QueryDb.operations<string, JSON.t>

type storage = {
  resources: array<Reventless.Adapter.resource>,
  dataSourceName: Pulumi.Output.t<string>, // TODO create in API
  operations: Pulumi.Output.t<operations>,
}
type storageMaker<'api, 'role> = (
  ~name: string,
  ~indexes: array<indexConfig>,
  ~subIdField: string=?,
  ~ttl: int=?,
  ~api: 'api,
  ~apiRole: 'role,
  ~opts: Pulumi.CustomResourceOptions.t,
) => storage

module type Storage = {
  type api
  type role

  let make: storageMaker<api, role>
}

type queryEngineMaker = dict<QueryDb.outputs> => Pulumi.Output.t<
  Reventless.QueryEngine.operations,
>

module type QueryEngineAdapter = {
  let make: queryEngineMaker
}

type resolvers = {
  resources: array<Reventless.Adapter.resource>,
  resourcesMaker: QueryDb.resolversResourcesMaker,
}
type resolversMaker<'api, 'role> = (
  ~name: string,
  ~api: 'api,
  ~apiRole: 'role,
  ~dataSourceName: Pulumi.Output.t<string>,
  ~indexes: array<indexConfig>,
  ~subIdField: option<string>,
  ~idResolverConfigs: array<idResolverConfig>,
  ~idsResolverConfigs: array<idsResolverConfig>,
  ~opts: Pulumi.CustomResourceOptions.t,
) => resolvers

module type Resolvers = {
  type api
  type role

  let make: resolversMaker<api, role>
}

module NoResolvers = (Storage: Storage) => {
  type api = Storage.api
  type role = Storage.role

  let make: resolversMaker<api, role> = (
    ~name as _: string,
    ~api as _: api,
    ~apiRole as _: role,
    ~dataSourceName as _,
    ~indexes as _: array<indexConfig>,
    ~subIdField as _,
    ~idResolverConfigs as _: array<idResolverConfig>,
    ~idsResolverConfigs as _: array<idsResolverConfig>,
    ~opts as _,
  ) => {
    resources: [],
    resourcesMaker: _ => [],
  }
}
