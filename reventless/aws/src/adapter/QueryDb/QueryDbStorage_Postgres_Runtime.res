// AWS-side runtime QueryDb operations for the Postgres backend. Mirrors the role
// of QueryDbStorage_DynamoDb_Runtime: turn a resolved connection config into the
// read-model operation set, bound to the container-lifetime pool from PgRuntime.
// Consumed by ReadModelEntryPoint.mjs / StateViewSliceEntryPoint.mjs (Postgres
// branch, selected when the handler's HANDLER_CONFIG entry carries a
// `pgConnection`).
//
// `name` is the read-model spec name — the same discriminator the deploy-time
// maker used, so runtime and deploy-time ops target the same `qdb_<name>` table.

let opsFor = (
  config: PgConnection.connectionConfig,
  ~name: string,
  ~indexes: array<Reventless.ReadModel.indexConfig>=[],
  ~subIdField: option<string>=?,
): ReventlessCore.QueryDb_Adapter.operations => {
  let pool = PgRuntime.poolFor(config)
  // Import the runtime-pure ops module (no @pulumi/pulumi) so this deployed-Lambda
  // path never drags a deploy-time dep into its ESM import graph.
  ReventlessPostgres.QueryDbStorage_Postgres_Ops.makeOperations(~pool, ~name, ~indexes, ~subIdField)
}
