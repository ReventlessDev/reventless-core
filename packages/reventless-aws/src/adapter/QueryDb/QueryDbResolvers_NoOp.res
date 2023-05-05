open Reventless
open ReventlessSpec.ReadModel.Spec

type api = unit
type role = unit

let make: QueryDb.Adapter.resolversMaker<api, role> = (
  ~name as _: string,
  ~api as _: api,
  ~apiRole as _: role,
  ~dataSourceName as _,
  ~indexes as _: array<index>,
  ~subIdField as _,
  ~resolveIdConfigs as _: array<resolveIdConfig>,
  ~resolveIdsConfigs as _: array<resolveIdsConfig>,
  ~opts as _,
) => {
  resources: [],
  resourcesMaker: _ => [],
}
