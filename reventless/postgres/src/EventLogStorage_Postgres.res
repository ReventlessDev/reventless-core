// Deploy/local wrapper over the runtime-pure EventLogStorage_Postgres_Ops.
//
// The runtime ops (and helpers like `countAll`) live in
// EventLogStorage_Postgres_Ops, which imports NO `@pulumi/pulumi` so the deployed
// Lambda import graph stays clean (the aggregate entry point pulls the ops in
// unconditionally at cold start — a deploy-time dep here would fail resolution on
// real Lambda). This module `include`s that pure module and adds only the
// deploy-time `EventLog_Adapter` shape (`operations` wrapped in `Pulumi.Output`),
// keeping the historic `makeStorage` 3-tuple `(name, ops, adapter)` API unchanged.
// See docs/plans/done/deployed-lambda-esm-self-containment.md (Rung-3 finding).

open ReventlessCore
include EventLogStorage_Postgres_Ops

let makeStorage = (~pool: PgDriver.pool, ~name: string, ~opts, ~onAppended=noTracking) => {
  let (name, ops) = makeOps(~pool, ~name, ~opts, ~onAppended)
  (name, ops, {EventLog_Adapter.resources: [], operations: Pulumi.Output.make(ops)})
}
