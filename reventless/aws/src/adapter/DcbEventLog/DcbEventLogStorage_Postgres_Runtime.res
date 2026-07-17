// AWS-side runtime DcbEventLog operations for the Postgres backend. The DCB
// analogue of EventLogStorage_Postgres_Runtime: turn a resolved connection config
// into the DCB operation set (`read`/`append`/`readStream`), bound to the
// container-lifetime pool from PgRuntime. Consumed by DcbCommandTopicEntryPoint.mjs
// (Postgres branch, selected when a PG_CONNECTION is present in HANDLER_CONFIG).
//
// The pg maker ignores `~indexes` / `~partitionTag` / `~crossPartitionTagKeys`
// (Postgres evaluates the real `DcbTag.query` atomically — no GSI routing), so
// they are passed empty here. `logName` is the `dcb_event.log_name` discriminator.

let opsFor = (
  config: PgConnection.connectionConfig,
  ~logName: string,
  ~lockStrategy: ReventlessPostgres.DcbEventLogStorage_Postgres_Ops.lockStrategy=#AdvisoryLocks,
): ReventlessCore.DcbEventLog_Adapter.operations => {
  let pool = PgRuntime.poolFor(config)
  // Import the runtime-pure ops module (no @pulumi/pulumi) so this deployed-Lambda
  // path never drags a deploy-time dep into its ESM import graph.
  let (_name, ops) = ReventlessPostgres.DcbEventLogStorage_Postgres_Ops.makeOps(
    ~pool,
    ~name=logName,
    ~indexes=[],
    ~partitionTag=(),
    ~opts=(),
    ~lockStrategy,
  )
  ops
}
