// AWS-side runtime EventLog operations for the Postgres backend. Mirrors the
// role of EventLogStorage_DynamoDb_Runtime: turn a resolved connection config
// into the classic EventLog operation set, bound to the container-lifetime pool
// from PgRuntime. Consumed by AggregateEntryPoint.mjs (Postgres branch, selected
// when a PG_CONNECTION is present in HANDLER_CONFIG).
//
// Unlike DynamoDB (table-per-aggregate), all aggregates share the single
// Postgres `event_log` table, discriminated by `log_name`. `logName` is that
// per-aggregate discriminator — the same stable identifier the builder would
// otherwise use as the DynamoDB table name.

let opsFor = (
  config: PgConnection.connectionConfig,
  ~logName: string,
): ReventlessCore.EventLog_Adapter.operations => {
  let pool = PgRuntime.poolFor(config)
  // Import the runtime-pure ops module (no @pulumi/pulumi) so this deployed-Lambda
  // path never drags a deploy-time dep into its ESM import graph.
  let (_name, ops) = ReventlessPostgres.EventLogStorage_Postgres_Ops.makeOps(
    ~pool,
    ~name=logName,
    ~opts=(),
  )
  ops
}
