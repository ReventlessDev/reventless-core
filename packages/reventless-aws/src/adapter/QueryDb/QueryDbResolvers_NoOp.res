open Reventless
open ReventlessSpec.ReadModel_Spec

type api = unit
type role = unit

let make: QueryDb_Adapter.resolversMaker<api, role> = (
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
