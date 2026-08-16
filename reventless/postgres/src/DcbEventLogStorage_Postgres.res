// Deploy/local wrapper over the runtime-pure DcbEventLogStorage_Postgres_Ops.
//
// The runtime ops, `lockStrategy`, `countAll`, and all query helpers live in
// DcbEventLogStorage_Postgres_Ops, which imports NO `@pulumi/pulumi` so the
// deployed Lambda import graph stays clean (the DCB command entry point pulls the
// ops in unconditionally at cold start — a deploy-time dep here would fail
// resolution on real Lambda). This module `include`s that pure module (so every
// existing `DcbEventLogStorage_Postgres.*` reference keeps working) and adds only
// the deploy-time `DcbEventLog_Adapter` shape, keeping the historic `makeStorage`
// 3-tuple `(name, ops, adapter)` API unchanged.
// See docs/plans/done/deployed-lambda-esm-self-containment.md (Rung-3 finding).

open ReventlessCore
include DcbEventLogStorage_Postgres_Ops

let makeStorage = (
  ~pool: PgDriver.pool,
  ~name: string,
  ~indexes,
  ~partitionTag,
  ~crossPartitionTagKeys=?,
  ~opts,
  ~lockStrategy: lockStrategy=#AdvisoryLocks,
  ~onAppended=noTracking,
) => {
  let (name, ops) = makeOps(
    ~pool,
    ~name,
    ~indexes,
    ~partitionTag,
    ~crossPartitionTagKeys?,
    ~opts,
    ~lockStrategy,
    ~onAppended,
  )
  (name, ops, {DcbEventLog_Adapter.resources: [], operations: Pulumi.Output.make(ops)})
}
