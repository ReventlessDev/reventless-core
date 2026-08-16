// Deploy/local wrapper over the runtime-pure QueryDbStorage_Postgres_Ops.
//
// `makeOperations` + all SQL helpers live in QueryDbStorage_Postgres_Ops, which
// imports NO `@pulumi/pulumi` so the deployed-Lambda runtime binds ops without
// dragging a deploy-time dep into its ESM import graph. This module `include`s
// that pure module (so every existing `QueryDbStorage_Postgres.*` reference keeps
// working) and adds only the deploy-time `Pulumi.Output`-shaped `storage` record
// and the `Make` provider functor.
// See docs/plans/done/deployed-lambda-esm-self-containment.md (Rung-3 finding).

open ReventlessCore
open Reventless.ReadModel
include QueryDbStorage_Postgres_Ops

let makeStorage = (
  ~pool: PgDriver.pool,
  ~name: string,
  ~indexes: array<indexConfig>,
  ~subIdField: option<string>,
): QueryDb_Adapter.storage => {
  {
    QueryDb_Adapter.resources: [],
    dataSourceName: ""->Pulumi.Output.make,
    operations: Pulumi.Output.make(makeOperations(~pool, ~name, ~indexes, ~subIdField)),
  }
}

// Standalone/deploy storage: inject the pool via a provider module.
module Make = (P: {let pool: PgDriver.pool}) => {
  type api = unit
  type role = unit

  let make: QueryDb_Adapter.storageMaker<unit, unit> = (
    ~name,
    ~indexes,
    ~subIdField=?,
    ~ttl as _=?,
    ~api as _,
    ~apiRole as _,
    ~owner as _, ~opts as _,
  ) => makeStorage(~pool=P.pool, ~name, ~indexes, ~subIdField)
}
