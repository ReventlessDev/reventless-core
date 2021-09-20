open Reventless;

type api = unit;
type role = unit;

let make: QueryDb.Adapter.resolversMaker(api, role) =
  (
    ~name as _: string,
    ~api as _: api,
    ~apiRole as _: role,
    ~dataSourceName as _,
    ~indexes as _: list(View.index),
    ~sortField as _,
    ~resolveIdConfigs as _: list(View.resolveIdConfig),
    ~resolveIdsConfigs as _: list(View.resolveIdsConfig),
    ~opts as _,
  ) => {
    {resources: [||], resourcesMaker: _ => [||]};
  };
