open Reventless
open ReventlessSpec.ReadModelSpec

type api = unit
type role = unit

let make: QueryDb.Adapter.resolversMaker<api, role> = (
  ~name as _: string,
  ~api as _: api,
  ~apiRole as _: role,
  ~dataSourceName as _,
  ~indexes as _: list<index>,
  ~subIdField as _,
  ~resolveIdConfigs as _: list<resolveIdConfig>,
  ~resolveIdsConfigs as _: list<resolveIdsConfig>,
  ~opts as _,
) => {
  resources: [],
  resourcesMaker: _ => [],
}
